local unicode

do
  local done
  done, unicode = pcall(require, "unicode")
  if not done then
    unicode = string
  end
end

local selenep = {}

local function getCurrentLine(lines, index, start, num)
  local curr = num or 0
  start = start or 1
  for i = start, #lines do
    if index <= curr + lines[i] then
      return i, curr
    end
    curr = curr + lines[i]
  end
  return #lines, 0
end

-------------------------------------------------------------------------------
-- Taken from text.lua and improved

local function trim(value) -- from http://lua-users.org/wiki/StringTrim
  local from = string.match(value, "^%s*()")
  return from > #value and "" or string.match(value, ".*%S", from)
end

local function tokenize(value, stripcomments)
  stripcomments = stripcomments or true
  if not value:find("\n$") then value = value.."\n" end
  local lines, currentlinecount = {}, 0
  local tokens, token = {}, ""
  local escaped, quoted, start = false, false, -1
  for i = 1, unicode.len(value) do
    local char = unicode.sub(value, i, i)
    if escaped then -- escaped character
      escaped = false
      token = token .. char
    elseif char == "\\" and quoted ~= "'" then -- escape character?
      escaped = true
      token = token .. char
    elseif char == "\n" and quoted == "--" then
      quoted = false
      if token ~= "" then
        if not stripcomments then
          table.insert(tokens, token)
          currentlinecount = currentlinecount + 1
        end
        token = ""
      end
      table.insert(lines, currentlinecount)
      currentlinecount = 0
    elseif char == "]" and quoted == "--[[" and string.find(token, "%]$") then
      quoted = false
      if token ~= "" then
        token = token..char
        if stripcomments then
          for w in token:gmatch("\n") do
            table.insert(lines, currentlinecount)
            if currentlinecount ~= 0 then currentlinecount = 0 end
          end
        else
          table.insert(tokens, token)
          currentlinecount = currentlinecount + 1
        end
        token = ""
      end
    elseif char == "[" and quoted == "--" and string.find(token, "%-%-%[$") then
      quoted = quoted .. "[["
      token = token .. char
    elseif char == quoted or (char == "]" and string.find(token, "%]=*$") and #(string.match(token, "%]=*$")..char) == #quoted) then -- end of quoted string
      quoted = false
      token = token .. char
    elseif (char == "'" or char == '"') and not quoted then
      quoted = char
      start = i
      token = token .. char
    elseif char == "-" and string.find(token, "%-$") and not quoted then
      local s = string.match(token, "%-$")
      quoted = s..char
      start = i - #s
      token = token .. char
    elseif (char == "[") and string.find(token, "%[=*$") and not quoted then -- derpy quote
      local s = string.match(token, "%[=*$")
      quoted = s..char
      start = i - #s
      token = token .. char
    elseif string.find(char, "%s") and not quoted then -- delimiter
      if token ~= "" then
        table.insert(tokens, token)
        currentlinecount = currentlinecount + 1
        token = ""
      end
      if char == "\n" then
        --io.write(unicode.sub(value, i-3, i-1).."\n")
        --io.write(#tokens.."   "..table.concat(lines, " ").."\n")
        table.insert(lines, currentlinecount)
        --io.write(#tokens.."   "..table.concat(lines, " ").."\n")
        currentlinecount = 0
      end
    elseif string.find(char, "[%(%)%$:%?,]") and not quoted then
      if token ~= "" then
        table.insert(tokens, token)
        currentlinecount = currentlinecount + 1
        token = ""
      end
      table.insert(tokens, char)
      currentlinecount = currentlinecount + 1
    elseif string.find(char, "[%->]") and string.find(token, "[%-=<]$") and not quoted then
      table.insert(tokens, token:sub(1, #token - 1))
      table.insert(tokens, token:sub(#token)..char)
      currentlinecount = currentlinecount + 2
      token = ""
    else -- normal char
      token = token .. char
    end
  end
  if quoted then
    return nil, "unclosed quote at index " .. start .. " (line "..getCurrentLine(lines, start, 1, 0)..")"
  end
  if token ~= "" then
    table.insert(tokens, token)
    currentlinecount = currentlinecount + 1
    table.insert(lines, currentlinecount)
  end
  local i = 1
  while i <= #tokens do
    if tokens[i] == nil or #tokens[i] <= 0 then
      table.remove(tokens, i)
      local l = getCurrentLine(lines, i)
      lines[l] = lines[l] - 1
    else
     tokens[i] = trim(tokens[i])
     i = i + 1
    end
  end
  return tokens, lines
end

-------------------------------------------------------------------------------

local varPattern = "[%a_][%w_]*"
--local lambdaParPattern = "("..varPattern..")((%s*,%s*)("..varPattern.."))*"

local function perror(msg, lvl)
  msg = msg or "unknown error"
  lvl = lvl or 1
  error("[Selene] error while parsing: "..msg, lvl + 1)
end

local function bracket(tChunk, plus, minus, step, result, incr, start)
  local curr = tChunk[step]
  local brackets = start or 1
  while brackets > 0 do
    if curr:find(plus, 1, true) then
      brackets = brackets + 1
    end
    if curr:find(minus, 1, true) then
      brackets = brackets - 1
    end
    if brackets > 0 then
      if incr > 0 then
        result = result.." "..curr
      else
        result = curr.." "..result
      end
      step = step + incr
      curr = tChunk[step]
    end
  end
  return result, step
end

local function split(self, sep)
  local t = {}
  local i = 1
  for str in self:gmatch("([^"..sep.."]+)") do
    t[i] = trim(str)
    i = i + 1
  end
  return t
end

local function tryAddReturn(code, stripcomments)
  local tChunk, msg = tokenize(code, stripcomments)
  chunk = nil
  if not tChunk then
    perror(msg)
  end
  msg = nil
  for _, part in ipairs(tChunk) do
    if part:find("^return$") then
      return code
    end
  end
  return "return "..code
end

local function findLambda(tChunk, i, part, lines, line, stripcomments)
  local params = {}
  local step = i - 1
  local inst, step = bracket(tChunk, ")", "(", step, "", -1)
  local params = split(inst, ",")
  local start = step
  step = i + 1
  local funcode, step = bracket(tChunk, "(", ")", step, "", 1)
  local stop = step
  if not funcode:find("return", 1, true) then
    funcode = "return "..funcode
  else
    funcode = tryAddReturn(funcode, stripcomments)
  end
  for _, s in ipairs(params) do
    if not s:find("^"..varPattern .. "$") then
      perror("invalid lambda at index "..i.. " (line "..line.."): invalid parameters")
    end
  end
  local func = "_G._selene._newFunc(function("..table.concat(params, ",")..") "..funcode.." end, "..tostring(#params)..")"
  --local l, s = 1, start
  for i = start, stop do
    table.remove(tChunk, start)
    local l1 =  getCurrentLine(lines, start, 1, 0)
    lines[l1] = lines[l1] - 1
  end
  table.insert(tChunk, start, func)
  lines[line] = lines[line] + 1
  return true
end

local function findDollars(tChunk, i, part, lines, line)
  local curr = tChunk[i + 1]
  if curr:find("^%(") then
    tChunk[i] = "_G._selene._new"
  elseif curr:find("^l") then
    tChunk[i] = "_G._selene._newList"
    table.remove(tChunk, i + 1)
    lines[line] = lines[line] - 1
  elseif curr:find("^f") then
    tChunk[i] = "_G._selene._newFunc"
    table.remove(tChunk, i + 1)
    lines[line] = lines[line] - 1
  elseif curr:find("^s") then
    tChunk[i] = "_G._selene._newString"
    table.remove(tChunk, i + 1)
    lines[line] = lines[line] - 1
  elseif tChunk[i - 1]:find("[:%.]$") then
    tChunk[i - 1] = tChunk[i - 1]:sub(1, #(tChunk[i - 1]) - 1)
    tChunk[i] = "()"
  else
    perror("invalid $ at index "..i.. " (line "..line..")")
  end
  return true
end

local function findSelfCall(tChunk, i, part, lines, line)
  if not tChunk[i + 2] then tChunk[i + 2] = "" end
  if tChunk[i + 1]:find(varPattern) and not tChunk[i + 2]:find("(", 1, true) then
    tChunk[i+1] = tChunk[i+1].."()"
    --table.insert(tChunk, i+2, ")")
    --table.insert(tChunk, i+2, "(")
    if line > #lines then
      perror("unexpected error while parsing self call at index "..step.. " (line "..line.."): invalid line number")
    end
    --print("Line lines 1: "..lines[line])
    --lines[line] = lines[line] + 2
    --print("Line lines 2: "..lines[line])
    --print(tChunk[i+1], tChunk[i+2], tChunk[i+3])
    return true
  end
  return false
end

local function findTernary(tChunk, i, part, lines, line)
  local step = i - 1
  local cond, step = bracket(tChunk, ")", "(", step, "", -1)
  local start = step
  step = i + 1
  local case, step = bracket(tChunk, "(", ")", step, "", 1)
  local stop = step
  if not case:find(":", 1, true) then
    perror("invalid ternary at index "..step.. " (line "..line.."): missing colon ':'")
  end
  local trueCase = case:sub(1, case:find(":", 1, true) - 1)
  local falseCase = case:sub(case:find(":", 1, true) + 1)
  local ternary = "(function() if "..cond.." then return "..trueCase.." else return "..falseCase.." end end)()"
  for i = start, stop do
    table.remove(tChunk, start)
    local l1 =  getCurrentLine(lines, start, 1, 0)
    lines[l1] = lines[l1] - 1
  end
  table.insert(tChunk, start, ternary)
  lines[line] = lines[line] + 1
  return true
end

local function findForeach(tChunk, i, part)
  local start = nil
  local step = i - 1
  local params = {}
  while not start do
    if tChunk[step] == "for" then
      start = step + 1
    else
      table.insert(params, 1, trim(tChunk[step]))
      step = step - 1
    end
  end
  params = split(table.concat(params), ",")
  step = i + 1
  local stop = nil
  local vars = {}
  while not stop do
    if tChunk[step] == "do" then
      stop = step - 1
    else
      table.insert(vars, trim(tChunk[step]))
      step = step + 1
    end
  end
  vars = split(table.concat(vars), ",")
  for _, p in ipairs(params) do
    if not p:find("^"..varPattern .. "$") then
      return false
    end
  end
  local func = table.concat(params, ",") .. " in _G.lpairs("..table.concat(vars, ",")..")"
  for i = start, stop do
    table.remove(tChunk, start)
    local l1 =  getCurrentLine(lines, start, 1, 0)
    lines[l1] = lines[l1] - 1
  end
  table.insert(tChunk, start, func)
  lines[line] = lines[line] + 1
  return true
end

--[[local types = {
  ["nil"] = true,
  ["boolean"] = true,
  ["string"] = true,
  ["number"] = true,
  ["table"] = true,
  ["function"] = true,
  ["thread"] = true,
  ["userdata"] = true,
  ["list"] = true,
  ["map"] = true,
  ["stringlist"] = true,
}

local function findMatch(tChunk, i, part)
  if not tChunk[i + 1]:find("(", 1, true) then
    perror("invalid match at index "..i..": no brackets () found")
  end
  local start = i
  local step = i + 2
  local cases, step = bracket(tChunk, "(", ")", step, "", 1)
  local stop = step
end]]

local keywords = {
  ["->"   ] = findLambda,
  ["=>"   ] = findLambda,
  ["<-"   ] = findForeach,
  ["?"    ] = findTernary,
  [":"    ] = findSelfCall,
  --["match"] = findMatch,
  ["$"    ] = findDollars
}

local function concatWithLines(tbl, lines)
  local chunktbl = {}
  for _,j in ipairs(lines) do
    local linetbl = {}
    for k = 1,j do
      table.insert(linetbl, tbl[1])
      table.remove(tbl, 1)
    end
    table.insert(chunktbl, table.concat(linetbl, " "))
  end
  for _,j in ipairs(tbl) do
    table.insert(chunktbl, j)
  end
  return table.concat(chunktbl, "\n")
end

local function parse(chunk, stripcomments)
  stripcomments = stripcomments or true
  local tChunk, lines = tokenize(chunk, stripcomments)
  chunk = nil
  if not tChunk then
    error(lines)
  end
  local currentline, currentnum = 1, 0
  for i, part in ipairs(tChunk) do
    if keywords[part] then
      if not tChunk[i + 1] then tChunk[i + 1] = "" end
      if not tChunk[i - 1] then tChunk[i - 1] = "" end
      currentline, currentnum = getCurrentLine(lines, i, currentline)
      local result = keywords[part](tChunk, i, part, lines, currentline, stripcomments)
      if result then
        local cnk = concatWithLines(tChunk, lines)
        tChunk = nil
        return parse(cnk, stripcomments)
      end
    end
  end
  --[[for i,j in ipairs(lines) do
    print(i,j)
  end
  print(table.concat(tChunk, " "))]]
  return concatWithLines(tChunk, lines)
end

function selenep.parse(chunk)
  return parse(chunk)
end

return selenep