-- vis-rg: live content search for vis, powered by ripgrep.
-- Load it at the top level of visrc.lua (the full screen picker is a second vis that loads it too):
--   local rg = require('plugins/vis-rg')
--   vis:map(vis.modes.NORMAL, ' g', function() rg.open() end)   -- or run :Rg [text]

local M = {
    rg = 'rg',
    args = {},                    -- extra flags for rg
    max_files = 500,
    max_matches = 30,             -- previewed per file
    context = 2,                  -- lines around each previewed match
    preview_lines = 200,          -- previewed when the query is empty
    max_size = 2 * 1024 * 1024,   -- bytes; bigger files are not previewed
    fullscreen = true,            -- false: a split of the running vis instead of a second, full screen vis
    styles = {},                  -- overrides, e.g. match = 'fore:black,back:green'
}

local floor, max, min, rep, find = math.floor, math.max, math.min, string.rep, string.find

local UTF8_RULES = {} -- lead byte -> { sequence length, lowest and highest valid second byte }
for lead = 0xC2, 0xDF do UTF8_RULES[lead] = { 2, 0x80, 0xBF } end
for lead = 0xE0, 0xEF do UTF8_RULES[lead] = { 3, 0x80, 0xBF } end
for lead = 0xF0, 0xF4 do UTF8_RULES[lead] = { 4, 0x80, 0xBF } end
UTF8_RULES[0xE0], UTF8_RULES[0xED] = { 3, 0xA0, 0xBF }, { 3, 0x80, 0x9F }
UTF8_RULES[0xF0], UTF8_RULES[0xF4] = { 4, 0x90, 0xBF }, { 4, 0x80, 0x8F }

-- Byte length of the valid UTF-8 sequence at text[i], or nil.
local function utf8_length(text, i)
    local lead = text:byte(i)
    if lead < 0x80 then return 1 end
    local rule = UTF8_RULES[lead]
    if not rule then return nil end
    local length, low, high = rule[1], rule[2], rule[3]
    local second = text:byte(i + 1)
    if not second or second < low or second > high then return nil end
    for k = 2, length - 1 do
        local continuation = text:byte(i + k)
        if not continuation or continuation < 0x80 or continuation > 0xBF then return nil end
    end
    return length
end

local function char_width(text, i, length)
    if length == 1 then return 1 end
    local b1, b2, b3, b4 = text:byte(i, i + length - 1)
    local cp
    if length == 2 then cp = (b1 - 0xC0) * 64 + b2 - 0x80
    elseif length == 3 then cp = (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + b3 - 0x80
    else cp = (b1 - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + b4 - 0x80 end
    if cp < 0x300 then return 1 end
    if cp <= 0x36F or (cp >= 0x200B and cp <= 0x200F) or (cp >= 0x20D0 and cp <= 0x20FF)
        or (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0xFEFF then
        return 0
    end
    if (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF and cp ~= 0x303F)
        or (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0xFE30 and cp <= 0xFE6F) or (cp >= 0xFF00 and cp <= 0xFF60)
        or (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1F64F)
        or (cp >= 0x1F900 and cp <= 0x1F9FF) or (cp >= 0x20000 and cp <= 0x3FFFD) then
        return 2
    end
    return 1
end

-- Tabs become two spaces, control characters and invalid UTF-8 become '?'.
local function printable(text)
    if find(text, '%c') then text = text:gsub('\t', '  '):gsub('%c', '?') end
    if not find(text, '[\128-\255]') then return text end
    local out, i = {}, 1
    while i <= #text do
        local a = find(text, '[\128-\255]', i)
        if not a then
            out[#out + 1] = text:sub(i)
            break
        end
        if a > i then out[#out + 1] = text:sub(i, a - 1) end
        local length = utf8_length(text, a)
        out[#out + 1] = length and text:sub(a, a + length - 1) or '?'
        i = a + (length or 1)
    end
    return table.concat(out)
end

-- Longest prefix of a printable text that fits in max_width columns, and its width.
local function truncate_end(text, max_width)
    if max_width <= 0 then return '', 0 end
    if not find(text, '[\128-\255]') then
        if #text <= max_width then return text, #text end
        return text:sub(1, max_width), max_width
    end
    local width, i = 0, 1
    while i <= #text do
        local length = utf8_length(text, i) or 1
        local w = char_width(text, i, length)
        if width + w > max_width then break end
        width, i = width + w, i + length
    end
    return text:sub(1, i - 1), width
end

-- Shortens from the left and keeps the end visible: "…rc/some/file.lua".
local function truncate_start(text, max_width)
    local head, head_width = truncate_end(text, max_width)
    if #head == #text then return text, head_width end
    if max_width <= 1 then return max_width == 1 and '…' or '', max(max_width, 0) end
    local room = max_width - 1
    if not find(text, '[\128-\255]') then return '…' .. text:sub(-room), max_width end
    local start = #text + 1
    while start > 1 do
        local i = start - 1
        while i > 1 and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do i = i - 1 end
        local w = char_width(text, i, utf8_length(text, i) or 1)
        if w > room then break end
        room, start = room - w, i
    end
    return '…' .. text:sub(start), max_width - room
end

-- Smart-case folding of ASCII, Latin-1, Greek and Cyrillic; every mapping keeps the byte length.
local LOWERCASE = {}
local function map_range(lead, first, last, new_lead, shift)
    for second = first, last do
        LOWERCASE[string.char(lead, second)] = string.char(new_lead, second + shift)
    end
end
map_range(0xC3, 0x80, 0x96, 0xC3, 32)
map_range(0xC3, 0x98, 0x9E, 0xC3, 32)
map_range(0xCE, 0x91, 0x9F, 0xCE, 32)
map_range(0xCE, 0xA0, 0xA9, 0xCF, -32)
map_range(0xD0, 0x90, 0x9F, 0xD0, 32)
map_range(0xD0, 0xA0, 0xAF, 0xD1, -32)
map_range(0xD0, 0x80, 0x8F, 0xD1, 16)

local function fold_case(text)
    text = text:lower()
    if find(text, '[\128-\255]') then text = text:gsub('[\195\206\208][\128-\191]', LOWERCASE) end
    return text
end

local function shell_quote(text)
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

local SECOND_VIS_ENV = 'VIS_RG_CHILD'
local handoff_path = os.getenv(SECOND_VIS_ENV) -- set only in the second vis
local picker                                   -- the open picker, or nil
local running = {}                             -- search name -> search, until its exit is seen
local finished_handles = {}                    -- released on the next redraw
local style_ids = {}
local search_count = 0
local rg_found = {}

local function theme_style(name)
    local style = vis.lexers and vis.lexers['STYLE_' .. name]
    if type(style) == 'table' then
        local parts = {}
        if style.attr then parts[#parts + 1] = tostring(style.attr) end
        if style.fore then parts[#parts + 1] = 'fore:' .. tostring(style.fore) end
        if style.back then parts[#parts + 1] = 'back:' .. tostring(style.back) end
        style = #parts > 0 and table.concat(parts, ',') or nil
    end
    if type(style) == 'string' then return style end -- '' is valid: the terminal default
end

local STYLES = { -- unset entries follow the theme style, or the fallback
    selected = { theme = 'SELECTION', fallback = 'reverse' },
    count = { theme = 'COMMENT', fallback = 'fore:244' },
    info = { theme = 'COMMENT', fallback = 'fore:244' },
    sep = { theme = 'COMMENT', fallback = 'fore:244' },
    lineno = { theme = 'LINENUMBER', fallback = 'fore:244' },
    match = { fallback = 'fore:black,back:#00ff00' },
    prompt = { fallback = 'bold' },
}

local function define_styles()
    local ui = vis.ui
    for name, source in pairs(STYLES) do
        local definition = M.styles[name] or (source.theme and theme_style(source.theme)) or source.fallback
        if style_ids[name] then
            ui:style_define(style_ids[name], definition)
        else
            style_ids[name] = ui:style_push(definition) or ui.style_ids.DEFAULT
        end
    end
end

-- The first line_limit lines of a text file; a note instead when it can't be shown.
local function read_head(path, line_limit)
    local file = io.open(path, 'rb')
    if not file then return {}, ' cannot read file' end
    if find(file:read(8192) or '', '\0', 1, true) then
        file:close()
        return {}, ' binary file'
    end
    local size = file:seek('end')
    if size and size > M.max_size then
        file:close()
        return {}, ' file too large'
    end
    file:seek('set', 0)
    local lines, count = {}, 0
    for line in file:lines() do
        count = count + 1
        lines[count] = line
        if count >= line_limit then break end
    end
    file:close()
    return lines
end

-- Rows of the preview pane, each already padded to `width`: a flat list of text, style, text, style, ...
local function preview_rows(entry, query, width)
    local last_hit = entry.lines[#entry.lines]
    local lines, note = read_head(entry.file, last_hit and last_hit + M.context or M.preview_lines)
    local line_count = #lines
    local hits = {}
    for _, number in ipairs(entry.lines) do
        if number <= line_count then hits[#hits + 1] = number end
    end
    local last_shown = #hits > 0 and min(line_count, hits[#hits] + M.context) or min(line_count, M.preview_lines)
    local digits = #tostring(last_shown)
    local text_width = max(width - digits - 1, 0)
    local case_sensitive = fold_case(query) ~= query

    local function code_row(number)
        local text, used = truncate_end(printable(lines[number]:sub(1, text_width * 4)), text_width)
        local row, from = { ('%' .. digits .. 'd '):format(number), 'lineno' }, 1
        if #hits > 0 then
            local haystack = case_sensitive and text or fold_case(text)
            local a = find(haystack, query, 1, true)
            while a do
                local n = #row
                row[n + 1], row[n + 2] = text:sub(from, a - 1), false
                row[n + 3], row[n + 4] = text:sub(a, a + #query - 1), 'match'
                from = a + #query
                a = find(haystack, query, from, true)
            end
        end
        local n = #row
        row[n + 1], row[n + 2] = text:sub(from) .. rep(' ', text_width - used), false
        return row
    end

    local rows = {}
    if #hits == 0 then
        for number = 1, last_shown do rows[number] = code_row(number) end
    else
        local shown = 0
        for _, hit in ipairs(hits) do
            local from, to = max(hit - M.context, 1), min(hit + M.context, line_count)
            if shown > 0 and from > shown + 1 then rows[#rows + 1] = { rep('─', width), 'sep' } end
            for number = max(from, shown + 1), to do rows[#rows + 1] = code_row(number) end
            shown = max(shown, to)
        end
    end
    if note then
        local text, used = truncate_end(note, width)
        rows[#rows + 1] = { text, 'info', rep(' ', width - used), false }
    end
    return rows
end

-- The whole picker is one line of text without newlines: every row is exactly as wide as the
-- window, so vis wraps it by itself and the last column can be used. (A newline needs a column
-- of its own, a row that fills the window would push it onto an extra row.)

local TL, TR, BL, BR, HZ, VT = '┌', '┐', '└', '┘', '─', '│'

local function box_top(title, outer_width)
    local fitted, fitted_width = truncate_end(title, outer_width - 2)
    return TL .. fitted .. rep(HZ, outer_width - 2 - fitted_width) .. TR
end

local function set_text(win, text)
    local file = win.file
    file:delete(0, file.size)
    file:insert(0, text)
end

local function render()
    local win = picker.win
    local width, height = win.viewport.width, win.viewport.height
    local list_outer = floor(width * 2 / 5)
    local list_width, preview_width, inner_height = list_outer - 2, width - list_outer - 2, height - 2
    if list_width < 8 or preview_width < 8 or inner_height < 3 then
        picker.spans = {}
        return set_text(win, 'window too small')
    end

    local results, selected = picker.results, picker.selected
    local current = results[selected]
    local preview = picker.preview
    if not (preview and preview.result == current and preview.width == preview_width) then
        preview = { result = current, width = preview_width,
            rows = current and preview_rows(current, picker.searched, preview_width) or {} }
        picker.preview = preview
    end
    local rows = preview.rows
    picker.scroll = max(0, min(picker.scroll, #rows - inner_height))

    local parts, spans, size, cursor = {}, {}, 0, 0
    local function put(text, style)
        local length = #text
        if length == 0 then return end
        local id = style and style_ids[style]
        if id then spans[#spans + 1] = { id, size, size + length - 1 } end
        parts[#parts + 1] = text
        size = size + length
    end

    local right_title = current and ' ' .. truncate_start(current.label, preview_width - 2) .. ' ' or ''
    put(box_top(' rg (' .. picker.total .. ' files) ', list_outer) .. box_top(right_title, width - list_outer))

    local list_rows = inner_height - 2
    local first = max(0, min(selected - 1 - floor(list_rows / 2), #results - list_rows)) -- keeps the selection centred
    for row = 1, inner_height do
        put(VT)
        if row == 1 then
            local typed, typed_width = truncate_start(picker.query, list_width - 3)
            put('> ' .. typed, 'prompt')
            cursor = size
            put(rep(' ', list_width - 2 - typed_width))
        elseif row == 2 then
            put(rep(HZ, list_width), 'sep')
        else
            local index = first + row - 2
            local entry = results[index]
            if entry then
                local count = entry.count > 0 and ' ' .. entry.count or ''
                if #count >= list_width then count = '' end
                local name, name_width = truncate_start(entry.label, list_width - #count)
                local padded = name .. rep(' ', list_width - #count - name_width)
                if index == selected then
                    put(padded .. count, 'selected')
                else
                    put(padded)
                    put(count, 'count')
                end
            elseif row == 3 and picker.loaded then
                local text, text_width = truncate_end(printable(' ' .. (picker.error_message or 'no matches')), list_width)
                put(text, 'info')
                put(rep(' ', list_width - text_width))
            else
                put(rep(' ', list_width))
            end
        end
        put(VT .. VT)
        local line = rows[picker.scroll + row]
        if line then
            for k = 1, #line, 2 do put(line[k], line[k + 1]) end
        else
            put(rep(' ', preview_width))
        end
        put(VT)
    end
    put(BL .. rep(HZ, list_width) .. BR .. BL .. rep(HZ, preview_width) .. BR)

    set_text(win, table.concat(parts))
    win.selection.pos = cursor
    picker.spans = spans
end

local SEARCH_FLAGS = '--line-number --no-heading --with-filename --null --color=never'
    .. ' --smart-case --fixed-strings --max-columns=500'

-- stdin is /dev/null because rg searches stdin instead of the directory when it is a pipe.
-- The output goes to a file, not a pipe: vis can see the process exit before the last chunk
-- of a pipe, which would silently drop part of the results.
local function ripgrep_command(query, output)
    local words = { 'exec', shell_quote(M.rg), query == '' and '--files --color=never' or SEARCH_FLAGS }
    for _, arg in ipairs(M.args) do words[#words + 1] = shell_quote(arg) end
    if query ~= '' then words[#words + 1] = '-- ' .. shell_quote(query) end
    words[#words + 1] = '>' .. shell_quote(output) .. ' 2>' .. shell_quote(output .. '.err') .. ' </dev/null'
    return table.concat(words, ' ')
end

-- Reads rg's output into a list of { file, label, count, lines }, sorted by path, and the number of files.
-- A search prints "<path> NUL <line>:<text>" per match, an empty query "<path>" per file.
local function parse_output(path, query)
    local output = io.open(path, 'rb')
    if not output then return {}, 0 end
    local by_path, paths = {}, {}
    for line in output:lines() do
        local raw_path, number = line, nil
        if query ~= '' then
            local nul = find(line, '\0', 1, true)
            number = nul and line:match('^(%d+):', nul + 1)
            raw_path = number and line:sub(1, nul - 1)
        end
        if raw_path and raw_path ~= '' then
            local entry = by_path[raw_path]
            if not entry then
                entry = { file = raw_path:gsub('^%./', ''), count = 0, lines = {} }
                by_path[raw_path] = entry
                paths[#paths + 1] = raw_path
            end
            if number then
                entry.count = entry.count + 1
                if entry.count <= M.max_matches then entry.lines[entry.count] = tonumber(number) end
            end
        end
    end
    output:close()
    table.sort(paths)
    local results = {}
    for i = 1, min(#paths, M.max_files) do
        local entry = by_path[paths[i]]
        entry.label = printable(entry.file)
        results[i] = entry
    end
    return results, #paths
end

local function show_results(search)
    local results, total = parse_output(search.output, search.query)
    local error_message
    if total == 0 then
        local err = io.open(search.output .. '.err', 'rb')
        if err then
            error_message = err:read('l')
            err:close()
        end
    end
    picker.results, picker.total, picker.error_message, picker.loaded = results, total, error_message, true
    picker.searched = search.query
    picker.selected = min(picker.selected, max(#results, 1))
    render()
end

local function start_search()
    search_count = search_count + 1
    local name = 'vis-rg:' .. search_count
    local output = os.tmpname()
    local handle, err = vis:communicate(name, ripgrep_command(picker.query, output))
    if not handle then
        os.remove(output)
        picker.search = nil
        vis:info('vis-rg: cannot start ' .. M.rg .. ': ' .. tostring(err))
        return
    end
    -- Older searches are never stopped, only outdated: their results are dropped when they finish.
    -- Their handle stays referenced until then: closing it (explicitly or through garbage collection)
    -- makes vis kill the process and close the stream's file descriptor a second time.
    picker.search = { handle = handle, output = output, query = picker.query }
    running[name] = picker.search
end

vis.events.subscribe(vis.events.PROCESS_RESPONSE, function(name, event)
    local search = running[name]
    if not search or (event ~= 'EXIT' and event ~= 'SIGNAL') then return end
    running[name] = nil
    -- vis closes the descriptor right after this handler returns: the handle must outlive that.
    finished_handles[#finished_handles + 1] = search.handle
    if picker and picker.search == search then
        picker.search = nil
        if event == 'EXIT' then show_results(search) end
    end
    os.remove(search.output)
    os.remove(search.output .. '.err')
end)

-- Open a file at a line in the window the search started from, like :edit.
-- When that would discard unsaved changes, open a split instead.
local function open_at(file, line)
    local origin = vis.win
    local argument = "'" .. file:gsub("'", "\\'") .. "'"
    if origin and origin.file and not origin.file.modified then vis:command('e ' .. argument) end
    if vis.win == origin then vis:command('open ' .. argument) end
    pcall(function() vis.ui.layout = vis.ui.layout end) -- re-arrange the windows now, for the final size
    local win = vis.win
    if win and win.file then
        win.selection:to(line, 1)
        vis:feedkeys('zz')
    end
end

-- The second vis hands its result back through a file: the file and the line to open, NUL separated.
local function hand_back(handoff, file, line)
    local out = io.open(handoff.out, 'wb')
    if out then
        out:write(file or '', '\0', line or '')
        out:close()
    end
    vis:exit(0)
end

local function close_picker(file, line)
    local closing = picker
    if not closing then return end
    picker = nil
    if closing.handoff then return hand_back(closing.handoff, file, line) end
    pcall(function() closing.win:close(true) end)
    if closing.layout then pcall(function() vis.ui.layout = closing.layout end) end -- :new stacked the windows
    if closing.origin then pcall(function() vis.win = closing.origin end) end
    vis.mode = vis.modes.NORMAL
    if file then open_at(file, line) end
end

function M.close() close_picker() end

local function open_selected()
    local entry = picker.results[picker.selected]
    if entry then close_picker(entry.file, entry.lines[1] or 1) end
end

local function query_changed()
    picker.selected, picker.scroll = 1, 0
    start_search()
    render()
end

local function move(delta)
    local count = #picker.results
    if count == 0 then return end
    picker.selected = (picker.selected - 1 + delta) % count + 1
    picker.scroll = 0
    render()
end

local function scroll(direction)
    picker.scroll = picker.scroll + direction * max(floor((picker.win.viewport.height - 2) / 2), 1)
    render()
end

local function backspace()
    local query = picker.query
    if query == '' then return end
    local i = #query
    while i > 1 and query:byte(i) >= 0x80 and query:byte(i) < 0xC0 do i = i - 1 end
    picker.query = query:sub(1, i - 1)
    query_changed()
end

local function setup_keys(win)
    local INSERT, ignore = vis.modes.INSERT, function() end
    -- Neutralise the other special keys of insert mode (<C-w>, <Tab>, ...) so nothing edits the buffer.
    -- Mappings of printable keys only, such as `jk` for Escape, are text the user types: they stay.
    for key in pairs(vis:mappings(INSERT)) do
        if find(key, '<', 1, true) then win:map(INSERT, key, ignore) end
    end
    local function bind(keys, action)
        for _, key in ipairs(keys) do win:map(INSERT, key, action) end
    end
    bind({ '<Escape>', '<C-c>' }, M.close)
    bind({ '<Enter>', '<C-y>' }, open_selected)
    bind({ '<C-n>', '<Down>', '<C-j>' }, function() move(1) end)
    bind({ '<C-p>', '<Up>', '<C-k>' }, function() move(-1) end)
    bind({ '<C-d>', '<C-f>', '<PageDown>' }, function() scroll(1) end)
    bind({ '<C-b>', '<C-u>', '<PageUp>' }, function() scroll(-1) end)
    bind({ '<Backspace>', '<C-h>', '<Delete>' }, backspace)
end

-- Printable keys arrive here; every key is swallowed while the picker is open.
vis.events.subscribe(vis.events.INPUT, function(key)
    if not picker or vis.win ~= picker.win then return end
    if key == '<lt>' then key = '<' end
    local byte = key:byte(1)
    if byte and byte >= 32 and byte ~= 127 and utf8_length(key, 1) == #key then
        picker.query = picker.query .. key
        query_changed()
    end
    return true
end)

vis.events.subscribe(vis.events.WIN_HIGHLIGHT, function(win)
    if not picker or win ~= picker.win then return end
    for _, span in ipairs(picker.spans) do win:style(span[1], span[2], span[3]) end
end)

vis.events.subscribe(vis.events.WIN_STATUS, function(win)
    if not picker or win ~= picker.win then return end
    win:status(' rg', 'Enter open  Esc close ')
    return true
end, 1)

-- Switching to insert mode inside the command that opened the picker makes vis lose the next key.
vis.events.subscribe(vis.events.UI_DRAW, function()
    if #finished_handles > 0 then finished_handles = {} end
    if picker and picker.want_insert and vis.win == picker.win then
        picker.want_insert = false
        vis.mode = vis.modes.INSERT
    end
end)

vis.events.subscribe(vis.events.WIN_CLOSE, function(win)
    if picker and win == picker.win then picker = nil end
end)

vis.events.subscribe(vis.events.QUIT, function()
    for _, search in pairs(running) do
        os.remove(search.output)
        os.remove(search.output .. '.err')
    end
end)

local function start_picker(win, initial_query, extra)
    define_styles()
    for _, option in ipairs({ 'cursorline', 'numbers', 'relativenumbers', 'showeof' }) do
        win.options[option] = false
    end
    picker = { win = win, query = initial_query or '', results = {}, total = 0, selected = 1, scroll = 0,
        spans = {}, want_insert = true }
    for key, value in pairs(extra) do picker[key] = value end
    setup_keys(win)
    render()
    start_search()
end

-- vis tiles its windows evenly and can't resize them, so a split takes half of the screen.
local function open_in_split(initial_query)
    local origin, layout = vis.win, vis.ui.layout
    if vis:command('new') then start_picker(vis.win, initial_query, { origin = origin, layout = layout }) end
end

local function serialize(value)
    if type(value) == 'table' then
        local items = {}
        for k, v in pairs(value) do items[#items + 1] = '[' .. serialize(k) .. ']=' .. serialize(v) end
        return '{' .. table.concat(items, ',') .. '}'
    end
    return type(value) == 'string' and string.format('%q', value) or tostring(value)
end

local vis_path
local function find_vis()
    if M.vis then return M.vis end
    if not vis_path then
        vis_path = 'vis'
        local pipe = io.popen('readlink /proc/$PPID/exe 2>/dev/null') -- the shell's parent is vis
        if pipe then
            local target = pipe:read('l')
            pipe:close()
            target = target and target:gsub(' %(deleted%)$', '')
            if target and target:sub(1, 1) == '/' then vis_path = target end
        end
    end
    return vis_path
end

-- The picker gets the whole screen by running in a second vis that has the terminal to itself,
-- the way fzf is used from an editor. Returns false when that could not be done.
local function run_second_vis(initial_query)
    local win = vis.win
    if not (win and win.file) then return false end
    local config_path, result_path = os.tmpname(), os.tmpname()
    local config_file = io.open(config_path, 'wb')
    if not config_file then
        os.remove(config_path)
        os.remove(result_path)
        return false
    end
    local config = {}
    for key, value in pairs(M) do
        if type(value) ~= 'function' then config[key] = value end
    end
    config_file:write('return ', serialize({ out = result_path, initial = initial_query or '', config = config }))
    config_file:close()

    -- vis hands its child its own pipes but draws on stderr and reads stdin: give it the terminal back.
    local command = 'env ' .. shell_quote(SECOND_VIS_ENV .. '=' .. config_path) .. ' '
        .. shell_quote(find_vis()) .. ' 2>/dev/tty </dev/tty'
    local ok, status = pcall(vis.pipe, vis, command, true)

    local result_file = io.open(result_path, 'rb')
    local result = result_file and result_file:read('a') or ''
    if result_file then result_file:close() end
    os.remove(config_path)
    os.remove(result_path)

    -- With the terminal gone vis would spin on a dead terminal and its pending hangup: quit instead.
    local tty = io.open('/dev/tty', 'r')
    if not tty then
        vis:exit(1)
        return true
    end
    tty:close()

    if ok and status == -1 then return true end -- killed by a signal: no second picker
    local separator = result:find('\0', 1, true)
    if not ok or status ~= 0 or not separator then return false end
    local file = result:sub(1, separator - 1)
    if file ~= '' then open_at(file, tonumber(result:sub(separator + 1)) or 1) end
    return true
end

-- In the second vis: replace the windows it started with by the picker.
local function start_as_second_vis()
    local chunk = loadfile(handoff_path)
    local handoff = chunk and chunk()
    if type(handoff) ~= 'table' or not vis:command('new') then return vis:exit(1) end
    local win = vis.win
    local others = {}
    for other in vis:windows() do
        if other ~= win then others[#others + 1] = other end
    end
    for _, other in ipairs(others) do other:close(true) end
    if #others > 0 then
        pcall(function() vis.win = win end)
        pcall(function() vis.ui.layout = vis.ui.layout end)
    end
    for key, value in pairs(handoff.config) do M[key] = value end
    start_picker(win, handoff.initial, { handoff = handoff })
end

if handoff_path then
    vis.events.subscribe(vis.events.START, function()
        if not pcall(start_as_second_vis) then vis:exit(1) end
    end)
end

function M.open(initial_query)
    if handoff_path then return end -- already the picker's own vis
    local found = rg_found[M.rg]
    if not found then
        local status = os.execute('command -v ' .. shell_quote(M.rg) .. ' >/dev/null 2>&1')
        found = status == true or status == 0 -- Lua 5.2+ returns true, 5.1 returns 0
        rg_found[M.rg] = found or nil -- look again next time, the user may fix their PATH
    end
    if not found then
        vis:info('vis-rg requires ripgrep (' .. M.rg .. ') to be installed and on your PATH.')
        return
    end
    M.close()
    if M.fullscreen then
        if run_second_vis(initial_query) then return end
        vis:info('vis-rg: could not start the full screen picker, using a split instead')
    end
    open_in_split(initial_query)
end

local function command(argv)
    M.open(table.concat(argv, ' '))
    return true
end
for _, name in ipairs({ 'Rg', 'rg' }) do
    vis:command_register(name, command, 'Live content search powered by ripgrep')
end

return M
