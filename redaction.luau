--!nonstrict
-- Presentation-only sanitization. Never transform an operation's executable inputs.
local Redaction = {}
local function sensitive(key: string): boolean
	local name = string.lower(key)
	return string.find(name, "token", 1, true) ~= nil
		or string.find(name, "password", 1, true) ~= nil
		or string.find(name, "secret", 1, true) ~= nil
		or string.find(name, "credential", 1, true) ~= nil
		or name == "authorization" or name == "pat" or string.match(name, "[_%-]pat$") ~= nil
		or string.match(name, "api[_%-]?key$") ~= nil or string.match(name, "access[_%-]?key$") ~= nil
end
function Redaction.text(value: any): string
	local text = tostring(value or "")
	text = string.gsub(text, "(%a[%w+%.%-]*://)[^/%s@]+@", "%1[redacted]@")
	text = string.gsub(text, "gh[pousr]_[%w_]+", "[redacted]")
	text = string.gsub(text, "github_pat_[%w_]+", "[redacted]")
	text = string.gsub(text, "([Bb][Ee][Aa][Rr][Ee][Rr]%s+)[%w%-%._~%+/=]+", "%1[redacted]")
	text = string.gsub(text, "([Bb][Aa][Ss][Ii][Cc]%s+)[%w%+/=]+", "%1[redacted]")
	local parts, cursor, search = {}, 1, 1
	while true do
		local first, last, key, value_at = string.find(text, "([%w_%-]+)[\"']?%s*[=:]%s*()", search)
		if not first then break end
		search = last + 1
		if sensitive(key) then
			local quote = string.sub(text, value_at, value_at)
			local stop
			if quote == '"' or quote == "'" then
				value_at += 1
				stop = string.find(text, quote, value_at, true) or (#text + 1)
				while stop <= #text and string.sub(text, stop - 1, stop - 1) == "\\" do
					stop = string.find(text, quote, stop + 1, true) or (#text + 1)
				end
			else
				stop = string.find(text, "[%s,;\"'<>]", value_at) or (#text + 1)
			end
			table.insert(parts, string.sub(text, cursor, value_at - 1))
			table.insert(parts, "[redacted]")
			cursor, search = stop, math.max(stop, last + 1)
		end
	end
	table.insert(parts, string.sub(text, cursor))
	text = table.concat(parts)
	return text
end
return Redaction
