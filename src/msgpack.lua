local bit = require 'bit'
local ffi = require 'ffi'
local native = ffi.C
local msgpack = require 'msgpack'

local uint16_ptr_t = ffi.typeof('uint16_t *')
local uint32_ptr_t = ffi.typeof('uint32_t *')

ffi.cdef([[

    enum mp_type {
        MP_NIL = 0,
        MP_UINT,
        MP_INT,
        MP_STR,
        MP_BIN,
        MP_ARRAY,
        MP_MAP,
        MP_BOOL,
        MP_FLOAT,
        MP_DOUBLE,
        MP_EXT
    };

    union intbuff {
        uint16_t u16;
        uint32_t u32;
        uint64_t u64;
    };

]])

local char_ptr_t = ffi.typeof('char *')
local bufp = ffi.new('const unsigned char *[1]');

local function init_type_hints_array(format)
    local xlat_table = {}
    for _, value in ipairs(format) do
        local from, to, filler = unpack(value)
        for i=from,to,1 do
            xlat_table[i] = filler
        end
    end
    return xlat_table
end

local mp_type_hints = init_type_hints_array({
    {0x00, 0x7f, native.MP_UINT}, -- MP_UINT (fixed)
    {0x80, 0x8f, native.MP_MAP}, -- MP_MAP (fixed)
    {0x90, 0x9f, native.MP_ARRAY}, -- MP_ARRAY (fixed)
    {0xa0, 0xbf, native.MP_STR}, -- MP_STR (fixed)
    {0xc0, 0xc0, native.MP_NIL}, -- MP_NIL
    {0xc1, 0xc1, native.MP_EXT}, -- MP_EXT -- never used
    {0xc2, 0xc3, native.MP_BOOL}, -- MP_BOOL
    {0xc4, 0xc6, native.MP_BIN}, -- MP_BIN(8|16|32)
    {0xc7, 0xc9, native.MP_EXT}, -- MP_EXT
    {0xca, 0xca, native.MP_FLOAT}, -- MP_FLOAT
    {0xcb, 0xcb, native.MP_DOUBLE}, -- MP_DOUBLE
    {0xcc, 0xcf, native.MP_UINT}, -- MP_UINT
    {0xd0, 0xd3, native.MP_INT}, -- MP_INT (8,16,32,64)
    {0xd4, 0xd8, native.MP_EXT}, -- MP_INT? (8,16,32,64,127)
    {0xd9, 0xdb, native.MP_STR}, -- MP_STR (8,16,32)
    {0xdc, 0xdd, native.MP_ARRAY}, -- MP_ARRAY (16,32)
    {0xde, 0xdf, native.MP_MAP}, -- MP_MAP (16,32)
    {0xe0, 0xff, native.MP_INT}, -- MP_INT
})

local function mp_typeof(c)
    return mp_type_hints[c] or native.MP_NIL
end

local intbuff
local strict_alignment = (jit.arch == 'arm' or
                          jit.arch == 'ppc' or
                          jit.arch == 'mips')

if strict_alignment then
   intbuff = ffi.new('union intbuff[1]')
end

local function bswap_u16(num)
    return bit.rshift(bit.bswap(tonumber(num)), 16)
end

local function decode_u16_risc(data)
    ffi.copy(intbuff, data[0], 2)
    data[0] = data[0] + 2
    return tonumber(bswap_u16(intbuff[0].u16))
end

local function decode_u32_risc(data)
    ffi.copy(intbuff, data[0], 4)
    data[0] = data[0] + 4
    return tonumber(ffi.cast('uint32_t', bit.bswap(tonumber(intbuff[0].u32))))
end

local function decode_u16_cisc(data)
    local num = bswap_u16(ffi.cast(uint16_ptr_t, data[0])[0])
    data[0] = data[0] + 2
    return tonumber(num)
end

local function decode_u32_cisc(data)
    local num = ffi.cast('uint32_t', bit.bswap(tonumber(ffi.cast(uint32_ptr_t, data[0])[0])))
    data[0] = data[0] + 4
    return tonumber(num)
end

local decode_u16
local decode_u32

if strict_alignment then
    decode_u16 = decode_u16_risc
    decode_u32 = decode_u32_risc
else
    decode_u16 = decode_u16_cisc
    decode_u32 = decode_u32_cisc
end

local function decode_array_header_slowly(c, data)
    -- fixarray: 0x90 .. 0x9f
    if bit.band(c, 0xf0) == 0x90 then
        return bit.band(c, 0xf)
    end

    -- array 16
    if c == 0xdc then
        return decode_u16(data)
    -- array 32
    elseif c == 0xdd then
        return decode_u32(data)
    else
        error('Unsupported MP_ARRAY')
    end
end

local function decode_array_header_compat(buf, size)
    if type(buf) == "string" then
        bufp[0] = ffi.cast(char_ptr_t, buf)
    elseif ffi.istype(char_ptr_t, buf) then
        bufp[0] = buf
    end

    local c = bufp[0][0]
    bufp[0] = bufp[0] + 1
    if (mp_typeof(c) ~= native.MP_ARRAY) then
        error(string.format("%s: unexpected msgpack type '0x%x'",
                            'decode_array_header_compat', c))
    end

    local len = decode_array_header_slowly(c, bufp)

    return len, ffi.cast(ffi.typeof(buf), bufp[0])
end

local function decode_map_header_slowly(c, data)
    -- fixmap: 0x80 .. 0x8f
    if bit.band(c, 0xf0) == 0x80 then
        return bit.band(c, 0xf)
    end

    -- map 16
    if c == 0xde then
        return decode_u16(data)
    -- map 32
    elseif c == 0xdf then
        return decode_u32(data)
    else
        error('Unsupported MP_MAP')
    end
end

local function decode_map_header_compat(buf, size)
    bufp[0] = buf

    local c = bufp[0][0]
    bufp[0] = bufp[0] + 1
    if (mp_typeof(c) ~= native.MP_MAP) then
        error(string.format("%s: unexpected msgpack type '0x%x'",
                            'decode_map_header_compat', c))
    end

    local len = decode_map_header_slowly(c, bufp)

    return len, ffi.cast(ffi.typeof(buf), bufp[0])
end

local IPROTO_DATA_KEY = 0x30

local function skip_request_header(self, buf)
    print(self, buf)
    -- nothing to do for not 1.10
    if not self.fix_compat then
        return
    end
    local len, key
    len, buf.rpos = self.decode_map_header(buf.rpos, buf:size())
    assert(len == 1)
    key, buf.rpos = self.decode_unchecked(buf.rpos)
    assert(key == IPROTO_DATA_KEY)
end

return {
    NULL = msgpack.NULL,
    new = msgpack.new,
    array_mt = msgpack.array_mt,
    cfg = msgpack.cfg,
    map_mt = msgpack.map_mt,

    ibuf_decode = msgpack.ibuf_decode,

    encode = msgpack.encode,
    decode = msgpack.decode,

    decode_unchecked = msgpack.decode_unchecked,
    decode_array_header = msgpack.decode_array_header or decode_array_header_compat,
    decode_map_header = msgpack.decode_map_header or decode_map_header_compat,
    fix_compat = msgpack.decode_map_header == nil,
    skip_request_header = skip_request_header,
}