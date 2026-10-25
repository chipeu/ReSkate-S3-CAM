-- A small JSON encoder / decoder for the offline tests, shaped like reskate.json (encode(value, pretty), decode(text)).
-- Arrays are tables with keys 1..n; objects are tables with string keys (sorted when encoded). null decodes to nil.
local json = {}

local BS = "\\"
local escapes = { ['"'] = BS .. '"', [BS] = BS .. BS, ["\n"] = BS .. "n", ["\r"] = BS .. "r", ["\t"] = BS .. "t", ["\b"] = BS .. "b", ["\f"] = BS .. "f" }

local function quote(s)
    local body = s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format(BS .. "u%04x", c:byte())
    end)
    return '"' .. body .. '"'
end

local function number_text(n)
    if n ~= n or n == math.huge or n == -math.huge then error("json: NaN or infinity cannot be encoded") end
    if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
    return string.format("%.17g", n)
end

local function is_array(t)
    local n = 0
    for _ in pairs(t) do n += 1 end
    if n == 0 then return true, 0 end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true, n
end

local function encode(v, pretty, indent, depth)
    if depth > 32 then error("json: tables nested deeper than 32") end
    local tv = type(v)
    if tv == "nil" then return "null" end
    if tv == "boolean" then return v and "true" or "false" end
    if tv == "number" then return number_text(v) end
    if tv == "string" then return quote(v) end
    if tv ~= "table" then error("json: cannot encode a " .. tv) end
    local nl, pad, pad_in, colon = "", "", "", ":"
    if pretty then nl, pad, pad_in, colon = "\n", indent, indent .. "  ", ": " end
    local array, n = is_array(v)
    local parts = {}
    if array then
        if n == 0 then return "[]" end
        for i = 1, n do parts[i] = pad_in .. encode(v[i], pretty, pad_in, depth + 1) end
        return "[" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "]"
    end
    local keys = {}
    for k in pairs(v) do
        if type(k) ~= "string" then error("json: a table mixes string keys and list keys") end
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do parts[i] = pad_in .. quote(k) .. colon .. encode(v[k], pretty, pad_in, depth + 1) end
    return "{" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "}"
end

function json.encode(value, pretty)
    return encode(value, pretty == true, "", 1)
end

local function fail(pos, what)
    error(string.format("json: %s at character %d", what, pos), 0)
end

local function skip(text, pos)
    return text:find("[^ \t\r\n]", pos) or #text + 1
end

local decode_value

local unescape = { ['"'] = '"', [BS] = BS, ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decode_string(text, pos)
    local out = {}
    local i = pos + 1
    while true do
        local c = text:sub(i, i)
        if c == "" then fail(i, "unterminated string") end
        if c == '"' then return table.concat(out), i + 1 end
        if c == BS then
            local e = text:sub(i + 1, i + 1)
            if unescape[e] then
                out[#out + 1] = unescape[e]
                i += 2
            elseif e == "u" then
                local hex = text:sub(i + 2, i + 5)
                if not hex:match("^%x%x%x%x$") then fail(i, "bad unicode escape") end
                local code = tonumber(hex, 16)
                i += 6
                if code >= 0xD800 and code <= 0xDBFF and text:sub(i, i + 1) == BS .. "u" then -- a surrogate pair
                    local low = tonumber(text:sub(i + 2, i + 5), 16)
                    if low and low >= 0xDC00 and low <= 0xDFFF then
                        code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                        i += 6
                    end
                end
                out[#out + 1] = utf8.char(code)
            else
                fail(i, "bad escape")
            end
        else
            local j = text:find('["\\]', i) or #text + 1
            out[#out + 1] = text:sub(i, j - 1)
            i = j
        end
    end
end

function decode_value(text, pos, depth)
    if depth > 32 then fail(pos, "nested deeper than 32") end
    pos = skip(text, pos)
    local c = text:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skip(text, pos + 1)
        if text:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            pos = skip(text, pos)
            if text:sub(pos, pos) ~= '"' then fail(pos, "expected a key") end
            local key
            key, pos = decode_string(text, pos)
            pos = skip(text, pos)
            if text:sub(pos, pos) ~= ":" then fail(pos, "expected ':'") end
            local value
            value, pos = decode_value(text, pos + 1, depth + 1)
            obj[key] = value
            pos = skip(text, pos)
            local d = text:sub(pos, pos)
            if d == "}" then return obj, pos + 1 end
            if d ~= "," then fail(pos, "expected ',' or '}'") end
            pos += 1
        end
    elseif c == "[" then
        local arr, n = {}, 0
        pos = skip(text, pos + 1)
        if text:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            local value
            value, pos = decode_value(text, pos, depth + 1)
            n += 1
            arr[n] = value
            pos = skip(text, pos)
            local d = text:sub(pos, pos)
            if d == "]" then return arr, pos + 1 end
            if d ~= "," then fail(pos, "expected ',' or ']'") end
            pos += 1
        end
    elseif c == '"' then
        return decode_string(text, pos)
    elseif text:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif text:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif text:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    end
    local s, e = text:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if not s then fail(pos, "unexpected character") end
    local n = tonumber(text:sub(s, e))
    if not n then fail(pos, "bad number") end
    return n, e + 1
end

function json.decode(text)
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
    local value, pos = decode_value(text, 1, 1)
    pos = skip(text, pos)
    if pos <= #text then fail(pos, "extra text after the value") end
    return value
end

return json
