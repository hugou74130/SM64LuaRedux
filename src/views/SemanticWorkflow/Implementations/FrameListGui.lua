--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

---@type FrameListGui
---@diagnostic disable-next-line: assign-type-mismatch
local __impl = __impl

---@type SemanticWorkflow
local semantic_workflow = dofile(processors_path .. 'SemanticWorkflow.lua')

-- table de conversion action → joypad pour exécution immédiate via clic
-- accepte soit un simple tableau de boutons (appui d'une frame), soit un
-- tableau `pattern` de plusieurs états. un champ `offset` peut être ajouté
-- afin de positionner la séquence en amont ou en aval de la cellule cliquée.
-- les valeurs doivent provenir de `test/stroop/Config/MarioActions.xml`.
local end_action_joypad = {
    -- long jump : quatre frames, deux Z puis deux A, débutant à la trame
    -- cliquée.
    [0x03000888] = {
        pattern = {
            { Z = true },
            { Z = true },
            { A = true },
            { A = true },
        }
    },
    [0x03000880] = { A = true },            -- single jump
    [0x008008A9] = { Z = true },            -- ground pound
    [0x18008AA] = { Z = true, B = true },   -- slide kick
    [0x0188088A] = { B = true },            -- air dive
    [0x00880456] = { A = true, B = true },  -- ground dive
    [0x18008AC] = { A = true, B = true },   -- air kick

    -- autres mappings ajoutables ici
}

--#region Constants

local MODE_TEXTS <const> = { '-', 'D', 'M', 'Y', 'R', 'A' }
local BUTTONS <const> = {
    { input = 'A',      text = 'A' },
    { input = 'B',      text = 'B' },
    { input = 'Z',      text = 'Z' },
    { input = 'start',  text = 'S' },
    { input = 'Cup',    text = '^' },
    { input = 'Cleft',  text = '<' },
    { input = 'Cright', text = '>' },
    { input = 'Cdown',  text = 'v' },
    { input = 'L',      text = 'L' },
    { input = 'R',      text = 'R' },
    { input = 'up',     text = '^' },
    { input = 'left',   text = '<' },
    { input = 'right',  text = '>' },
    { input = 'v',      text = 'v' },
}

local COL0 <const> = 0.0
local COL1 <const> = 1.3
local COL2 <const> = 1.8
local COL3 <const> = 2.1
local COL4 <const> = 2.3
local COL5 <const> = 3.1
local COL6 <const> = 3.3
local COL_1 <const> = 8.0

local ROW0 <const> = 1.00
local ROW1 <const> = 1.50
local ROW2 <const> = 2.25

local BUTTON_COLUMN_WIDTH <const> = 0.3
local BUTTON_SIZE <const> = 0.22
local FRAME_COLUMN_HEIGHT <const> = 0.5
local SCROLLBAR_WIDTH <const> = 0.3

local MAX_DISPLAYED_SECTIONS <const> = 15

local NUM_UIDS_PER_ROW <const> = 2
local BUTTON_COLORS <const> = {
    { background = '#0000FF64', button = '#0000BEFF' }, -- A
    { background = '#00B11664', button = '#00E62CFF' }, -- B
    { background = '#6F6F6F64', button = '#C8C8C8FF' }, -- Z
    { background = '#C8000064', button = '#FF0000FF' }, -- Start
    { background = '#C8C80064', button = '#FFFF00FF' }, -- 4 C Buttons
    { background = '#6F6F6F64', button = '#C8C8C8FF' }, -- L + R Buttons
    { background = '#37373764', button = '#323232FF' }, -- 4 DPad Buttons
}

local VIEW_MODE_HEADERS <const> = { 'SEMANTIC_WORKFLOW_FRAMELIST_STICK', 'SEMANTIC_WORKFLOW_FRAMELIST_UNTIL', 'SEMANTIC_WORKFLOW_FRAMELIST_NUMERIC' }

-- Palette for section color tags. Index 0 = no color.
local SECTION_COLOR_PALETTE <const> = {
    '#FF404088', -- 1 Red/pink
    '#FF8000AA', -- 2 Orange
    '#C8C800AA', -- 3 Yellow
    '#00CC44AA', -- 4 Green
    '#00CCCCAA', -- 5 Cyan
    '#4080FFAA', -- 6 Blue
    '#9040FFAA', -- 7 Purple
    '#FFFFFFAA', -- 8 White
}

--#endregion

--#region logic

local scroll_offset = 0
local last_active_section = 0
local last_active_frame_idx = 0

-- Note: semantic_workflow.perform is not implemented in the processor
-- (it only provides transform/readback). previous versions attempted to
-- inject immediate overrides via a queue, but editing the sheet directly
-- now handles long‑jump playback. therefore the queue logic has been
-- removed entirely.

local UID = UIDProvider.allocate_once('FrameListGui', function(enum_next)
    local base = enum_next(MAX_DISPLAYED_SECTIONS * NUM_UIDS_PER_ROW)
    return {
        SheetName = enum_next(),
        Scrollbar = enum_next(),
        Row = function(index)
            return base + (index - 1) * NUM_UIDS_PER_ROW
        end,
    }
end)

---@alias IterateInputsCallback fun(section: Section, input: SectionInputs, section_index: integer, total_inputs_counted: integer, input_index: integer): boolean?

---@function Iterates all sections as an input row, including their follow-up frames for non-collapsed sections.
---@param sheet Sheet The sheet over whose sections to iterate.
---@param callback IterateInputsCallback? an optional function that, when it returns true, terminates the enumeration.
local function iterate_input_rows(sheet, callback)
    local total_inputs_counted = 1
    local total_sections_counted = 1
    for section_index = 1, #sheet.sections, 1 do
        local section = sheet.sections[section_index]
        for input_index = 1, #section.inputs, 1 do
            if callback and callback(section, section.inputs[input_index], total_sections_counted, total_inputs_counted, input_index) then
                return total_inputs_counted
            end

            total_inputs_counted = total_inputs_counted + 1
            if section.collapsed then break end
        end
        total_sections_counted = total_sections_counted + 1
    end
    return total_inputs_counted - 1
end

local function update_scroll(wheel, num_rows)
    scroll_offset = math.max(0, math.min(num_rows - MAX_DISPLAYED_SECTIONS, scroll_offset - wheel))
end

--- Returns the 1-based row index of a given (section, frame) pair in the
--- visible row stream, taking collapsed state into account.
local function compute_row_of(sheet, target_sec, target_frame)
    local row = 0
    for si = 1, #sheet.sections do
        local sec = sheet.sections[si]
        local visible = sec.collapsed and 1 or #sec.inputs
        if si < target_sec then
            row = row + visible
        elseif si == target_sec then
            row = row + math.min(target_frame, visible)
            break
        end
    end
    return row
end

local function interpolate_vectors_to_int(a, b, f)
    local result = {}
    for k, v in pairs(a) do
        result[k] = math.floor(v + (b[k] - v) * f)
    end
    return result
end

local function draw_headers(sheet, draw, view_index, button_draw_data)
    local background_color = interpolate_vectors_to_int(draw.background_color, { r = 127, g = 127, b = 127 }, 0.25)
    BreitbandGraphics.fill_rectangle(grid_rect(0, ROW0, COL_1, ROW2 - ROW0, 0), background_color)

    draw:text(grid_rect(3, ROW0, 1, 0.5), 'start', Locales.str('SEMANTIC_WORKFLOW_FRAMELIST_NAME'))
    sheet.name = ugui.textbox({
        uid = UID.SheetName,
        is_enabled = true,
        rectangle = grid_rect(4, ROW0, 4, 0.5),
        text = sheet.name,
        styler_mixin = {
            font_size = ugui.standard_styler.params.font_size * 0.75,
        },
    })
    SemanticWorkflowProject:set_current_name(sheet.name)

    draw:text(grid_rect(COL0, ROW1, COL1 - COL0, 1), 'start', Locales.str('SEMANTIC_WORKFLOW_FRAMELIST_SECTION'))
    draw:text(grid_rect(COL1, ROW1, COL6 - COL1, 1), 'start', Locales.str(VIEW_MODE_HEADERS[view_index]))

    -- Stats: total sections, total frames, selected count, estimated duration, dirty marker
    local total_inputs_count, total_timeout_count, sel_count = 0, 0, 0
    for _, s in ipairs(sheet.sections) do
        total_inputs_count = total_inputs_count + #s.inputs
        total_timeout_count = total_timeout_count + s.timeout
        for _, inp in ipairs(s.inputs) do
            if inp.editing then sel_count = sel_count + 1 end
        end
    end
    local duration_s = string.format('%.1f', total_timeout_count / 30)
    local dirty_mark = SemanticWorkflowProject.dirty and ' [*]' or ''
    local sel_str = sel_count > 0 and ('  [' .. sel_count .. '\xe2\x98\x85]') or ''
    draw:small_text(grid_rect(0, ROW0, 3, 0.5), 'start',
        'S:' .. #sheet.sections .. '  F:' .. total_inputs_count .. '/' .. total_timeout_count
        .. ' (~' .. duration_s .. 's)' .. sel_str .. dirty_mark)

    -- Mini timeline: proportional bars showing each section's planned duration (timeout)
    if total_timeout_count > 0 then
        local tl_rect = grid_rect(COL0, ROW2 - 0.2, COL_1 - SCROLLBAR_WIDTH, 0.2, 0)
        local tl_x = tl_rect.x
        local tl_w = tl_rect.width
        local tl_y = tl_rect.y
        local tl_h = tl_rect.height
        local cur_x = tl_x
        for si, sec in ipairs(sheet.sections) do
            local frac = sec.timeout / total_timeout_count
            local seg_w = math.max(1, math.floor(tl_w * frac))
            if si == #sheet.sections then seg_w = tl_x + tl_w - cur_x end
            local color = (sec.color_tag and sec.color_tag > 0 and SECTION_COLOR_PALETTE[sec.color_tag]) or
                (si % 2 == 0 and '#88888866' or '#AAAAAA66')
            BreitbandGraphics.fill_rectangle({ x = cur_x, y = tl_y, width = seg_w, height = tl_h }, color)
            cur_x = cur_x + seg_w
        end
        -- Highlight the active section in the timeline with white border
        local active_si = sheet.active_frame.section_index
        local offset_x = tl_x
        for si, sec in ipairs(sheet.sections) do
            local frac = sec.timeout / total_timeout_count
            local seg_w = math.max(1, math.floor(tl_w * frac))
            if si == #sheet.sections then seg_w = tl_x + tl_w - offset_x end
            if si == active_si then
                BreitbandGraphics.draw_rectangle({ x = offset_x, y = tl_y, width = seg_w, height = tl_h }, '#FFFFFFFF', 1)
                break
            end
            offset_x = offset_x + seg_w
        end
        -- Active frame position marker: thin vertical white line
        local active_global = 0
        for j = 1, active_si - 1 do active_global = active_global + sheet.sections[j].timeout end
        active_global = active_global + sheet.active_frame.frame_index
        local marker_x = math.floor(tl_x + tl_w * (active_global / total_timeout_count))
        BreitbandGraphics.fill_rectangle({ x = marker_x - 1, y = tl_y, width = 2, height = tl_h }, '#FFFFFFFF')
    end

    if not button_draw_data then return end

    local rect = grid_rect(0, ROW1, 0.333, 1)
    for i, v in ipairs(BUTTONS) do
        rect.x = button_draw_data[i].x
        draw:text(rect, 'center', v.text)
    end
end

local function draw_scrollbar(num_rows)
    local baseline = grid_rect(COL_1, ROW2, BUTTON_COLUMN_WIDTH, FRAME_COLUMN_HEIGHT, 0)
    local unit = Settings.grid_size * Drawing.scale
    local num_actually_shown_rows = math.min(MAX_DISPLAYED_SECTIONS, num_rows)
    local scrollbar_rect = {
        x = baseline.x - SCROLLBAR_WIDTH * unit,
        y = baseline.y,
        width = SCROLLBAR_WIDTH * unit,
        height = baseline.height * num_actually_shown_rows,
    }

    local max_scroll = num_rows - MAX_DISPLAYED_SECTIONS
    if num_rows > 0 and max_scroll > 0 then
        local relative_scroll = ugui.scrollbar({
            uid = UID.Scrollbar,
            rectangle = scrollbar_rect,
            value = scroll_offset / max_scroll,
            ratio = num_actually_shown_rows / num_rows,
        })
        scroll_offset = math.floor(relative_scroll * max_scroll + 0.5)
    end

    return baseline, scrollbar_rect
end

local function draw_color_codes(baseline, scrollbar_rect, num_display_sections)
    local rect = {
        x = scrollbar_rect.x - baseline.width * #BUTTONS,
        y = baseline.y,
        width = baseline.width,
        height = baseline.height * num_display_sections,
    }

    local f = Settings.grid_size * Drawing.scale
    BreitbandGraphics.fill_rectangle(
        { x = COL0 * f + Drawing.initial_size.width, y = rect.y, width = (COL1 - COL0) * f, height = rect.height },
        '#FF000028'
    )

    local i = 1
    local color_index = 1
    local button_draw_data = {}

    local function draw_next(amount)
        for k = 0, amount - 1, 1 do
            button_draw_data[i] = { x = rect.x + k * rect.width, color_index = color_index }
            i = i + 1
        end
        BreitbandGraphics.fill_rectangle(
            { x = rect.x, y = rect.y, width = rect.width * amount, height = rect.height },
            BUTTON_COLORS[color_index].background
        )
        color_index = color_index + 1
        rect.x = rect.x + rect.width * amount
    end

    draw_next(1) -- A
    draw_next(1) -- B
    draw_next(1) -- Z
    draw_next(1) -- Start
    draw_next(4) -- 4 C Buttons
    draw_next(2) -- L + R Buttons
    draw_next(4) -- 4 DPad Buttons
    button_draw_data[#button_draw_data + 1] = { x = rect.x }

    return button_draw_data
end

local placing = 0
local function handle_scroll_and_buttons(section_rect, button_draw_data, num_rows)
    local mouse_x = ugui_environment.mouse_position.x
    local relative_y = ugui_environment.mouse_position.y - section_rect.y
    local in_range = mouse_x >= section_rect.x and mouse_x <= section_rect.x + section_rect.width and relative_y >= 0
    local unscrolled_hover_index = math.ceil(relative_y / section_rect.height)
    local hovering_index = unscrolled_hover_index + scroll_offset
    local any_change = false
    in_range = in_range and unscrolled_hover_index <= MAX_DISPLAYED_SECTIONS
    update_scroll(in_range and ugui_environment.wheel or 0, num_rows)
    if in_range then
        -- act as if the mouse wheel was not moved in order to prevent other controls from scrolling on accident
        ugui_environment.wheel = 0
        ugui.internal.environment.wheel = 0
    end

    if not button_draw_data then return end

    iterate_input_rows(SemanticWorkflowProject:asserted_current(), function(section, input, section_index, input_index)
        if input_index == hovering_index and in_range and section ~= nil then
            for button_index, v in ipairs(BUTTONS) do
                local in_range_x = mouse_x >= button_draw_data[button_index].x and
                    mouse_x < button_draw_data[button_index + 1].x
                if ugui.internal.is_mouse_just_down() and in_range_x then
                    placing = input.joy[v.input] and -1 or 1
                    input.joy[v.input] = placing
                    any_change = true
                elseif ugui.internal.environment.is_primary_down and placing ~= 0 then
                    if in_range_x then
                        any_change = input.joy[v.input] ~= (placing == 1)
                        input.joy[v.input] = placing == 1
                    end
                else
                    placing = 0
                end
            end
        end
    end)
    return any_change
end

---@param sheet Sheet
---@param action_code integer
---@param sheet Sheet? optional sheet to mutate
---@param sec_index number? section index
---@param frame_index number? frame index
local function perform_end_action(action_code, sheet, sec_index, frame_index)
    local mapping = end_action_joypad[action_code]
    if not mapping then return end
    local pattern = mapping.pattern and mapping.pattern or { mapping }

    if sheet and sec_index and frame_index then
        local sec = sheet.sections[sec_index]
        if sec then
            local offs = mapping.offset or 0
            local targets = {}
            local min_i, max_i = math.huge, -math.huge
            for i = 1, #pattern do
                local idx = frame_index + offs + i - 1
                targets[i] = idx
                min_i = math.min(min_i, idx)
                max_i = math.max(max_i, idx)
            end
            if min_i < 1 then
                local push = 1 - min_i
                for _ = 1, push do
                    local tmp = {}
                    CloneInto(tmp, Joypad.input)
                    table.insert(sec.inputs, 1, { tas_state = NewTASState(), joy = tmp })
                end
                for i = 1, #targets do targets[i] = targets[i] + push end
                max_i = max_i + push
            end
            while #sec.inputs < max_i do
                local tmp = {}
                CloneInto(tmp, Joypad.input)
                table.insert(sec.inputs, { tas_state = NewTASState(), joy = tmp })
            end
            for i, joy in ipairs(pattern) do
                local dest = sec.inputs[targets[i]].joy
                for k, v in pairs(joy) do dest[k] = v end
            end
            sheet:run_to_preview()
        end
    end
    -- we no longer send overrides; pattern entries are written into the
    -- sheet itself above.
end

local function draw_sections_gui(sheet, draw, view_index, section_rect, button_draw_data)
    local function span(x1, x2, height)
        local r = grid_rect(x1, 0, x2 - x1, height, 0)
        return { x = r.x, y = section_rect.y, width = r.width, height = height and r.height or section_rect.height }
    end

    -- Pre-compute cumulative frame offsets per section (frames before each section start)
    local cum_frames = {}
    local cum_total = 0
    for si = 1, #sheet.sections do
        cum_frames[si] = cum_total
        cum_total = cum_total + #sheet.sections[si].inputs
    end

    iterate_input_rows(sheet, function(section, input, section_index, total_inputs, input_sub_index)
        if total_inputs <= scroll_offset then return false end

        --TODO: color code section success
        local shade = total_inputs % 2 == 0 and 123 or 80
        local blue_multiplier = section_index % 2 == 1 and 2 or 1

        if total_inputs > MAX_DISPLAYED_SECTIONS + scroll_offset then
            local extra_sections = #sheet.sections - section_index
            BreitbandGraphics.fill_rectangle(span(0, COL_1), '#8A948A42')
            draw:text(span(COL1, COL_1), 'start', '+ ' .. extra_sections .. ' sections')
            return true
        end

        local tas_state = input.tas_state
        local frame_box = span(COL0 + 0.3, COL1)

        local uid_base = UID.Row(total_inputs - scroll_offset)

        -- Active simulation: tint the executing section with a cyan overlay
        local is_executing = sheet.busy and section_index == sheet._section_index
        BreitbandGraphics.fill_rectangle(section_rect, { r = shade, g = shade, b = shade * blue_multiplier, a = is_executing and 90 or 66 })
        if is_executing then
            BreitbandGraphics.fill_rectangle(section_rect, { r = 0, g = 200, b = 180, a = 30 })
        end

        -- Playback progress bar: thin green bar at the bottom of the executing section row
        if sheet.busy and section_index == sheet._section_index and input_sub_index == 1 then
            local progress = math.min(1.0, sheet._frame_counter / math.max(1, math.min(#section.inputs, section.timeout)))
            BreitbandGraphics.fill_rectangle({
                x = section_rect.x,
                y = section_rect.y + section_rect.height - 2,
                width = section_rect.width * progress,
                height = 2,
            }, '#00FF88FF')
        end

        -- Section color tag: colored 4px bar on left edge for all rows of this section
        if section.color_tag and section.color_tag > 0 then
            local color = SECTION_COLOR_PALETTE[section.color_tag]
            if color then
                BreitbandGraphics.fill_rectangle({
                    x = section_rect.x,
                    y = section_rect.y,
                    width = 4,
                    height = section_rect.height,
                }, color)
            end
        end

        if input_sub_index == 1 then
            section.collapsed = not ugui.toggle_button({
                uid = uid_base + 0,
                rectangle = span(COL0, COL0 + 0.3),
                text = section.collapsed and '[icon:arrow_right]' or '[icon:arrow_down]',
                tooltip = Locales.str(section.collapsed and 'SEMANTIC_WORKFLOW_INPUTS_EXPAND_SECTION' or
                    'SEMANTIC_WORKFLOW_INPUTS_COLLAPSE_SECTION'),
                is_checked = not section.collapsed,
                is_enabled = #section.inputs > 1,
            }) or #section.inputs == 1;
        end

        draw:text(frame_box, 'end', section_index .. ':')

        if ugui.internal.is_mouse_just_down() and BreitbandGraphics.is_point_inside_rectangle(ugui_environment.mouse_position, frame_box) then
            sheet.preview_frame = { section_index = section_index, frame_index = input_sub_index }
            sheet:run_to_preview()
        end

        local active_frame_box = span(COL1, COL6)
        if view_index == 1 then
            -- mini joysticks and yaw numbers
            local joystick_box = span(COL1, COL2)
            ugui.joystick({
                uid = uid_base + 1,
                rectangle = span(COL1, COL2, FRAME_COLUMN_HEIGHT),
                position = { x = (input.joy and input.joy.X) or 0, y = -((input.joy and input.joy.Y) or 0) },
                styler_mixin = {
                    joystick = {
                        tip_size = 4 * Drawing.scale,
                    },
                },
            })

            if BreitbandGraphics.is_point_inside_rectangle(ugui_environment.mouse_position, joystick_box) then
                if ugui.internal.is_mouse_just_down() and not ugui_environment.held_keys['control'] then
                    for _, section in pairs(sheet.sections) do
                        for _, input in pairs(section.inputs) do
                            input.editing = false
                        end
                    end
                    input.editing = true
                elseif ugui.internal.environment.is_primary_down then
                    input.editing = true
                end
            end

            if input.editing then
                defer(function()
                    BreitbandGraphics.fill_rectangle(joystick_box, '#00C80064')
                end)
            end

            draw:text(span(COL2, COL3), 'center', MODE_TEXTS[tas_state.movement_mode + 1])

            if tas_state.movement_mode == MovementModes.match_angle then
                draw:text(span(COL4, COL5), 'end', tostring(tas_state.goal_angle))
                draw:text(span(COL5, COL6), 'end',
                    tas_state.strain_left and '<' or (tas_state.strain_right and '>' or '-'))
            elseif input_sub_index == 1 then
                -- show frame count in the unused angle space
                draw:small_text(span(COL3, COL6), 'end', '×' .. #section.inputs)
            end
        elseif view_index == 2 then
            -- end action with cumulative frame offset and count (first row only)
            local label_prefix = (section.label and section.label ~= '') and (section.label .. ' · ') or ''
            if input_sub_index == 1 then
                local cum = cum_frames[section_index]
                local text = string.format('[+%d] %s%s  ×%d', cum, label_prefix, Locales.action(section.end_action), #section.inputs)
                draw:text(active_frame_box, 'start', text)
            else
                draw:text(active_frame_box, 'start', label_prefix .. Locales.action(section.end_action))
            end
        elseif view_index == 3 then
            -- numeric: mode, X/Y or angle, magnitude, flags
            local ts = tas_state
            local mode_char = MODE_TEXTS[ts.movement_mode + 1]
            local x = (input.joy and input.joy.X) or 0
            local y = (input.joy and input.joy.Y) or 0
            local angle_str = ts.movement_mode == MovementModes.match_angle
                and string.format('A:%5d', ts.goal_angle)
                or string.format('X:%-4d Y:%-4d', x, y)
            local flags = (ts.framewalk and 'FW ' or '') .. (ts.swim and 'SW' or '')
            local text = string.format('%s %s M:%-3d %s', mode_char, angle_str, ts.goal_mag or 0, flags)
            draw:small_text(active_frame_box, 'start', text)
        end

        if BreitbandGraphics.is_point_inside_rectangle(ugui_environment.mouse_position, active_frame_box) then
            if ugui.internal.is_mouse_just_down() then
                -- when we are in the "end action" view (view_index==2), a click
                -- on the cell should also fire the semantic action if we know
                -- a mapping for it.
                if view_index == 2 then
                    local sheet = SemanticWorkflowProject:asserted_current()
                    perform_end_action(section.end_action, sheet, section_index, input_sub_index)
                end

                if __impl.special_select_handler then
                    __impl.special_select_handler({ section_index = section_index, frame_index = input_sub_index })
                else
                    sheet.active_frame = { section_index = section_index, frame_index = input_sub_index }
                end
            end
        end

        -- Section timeout progress: thin bar at section row top showing inputs/timeout ratio
        if input_sub_index == 1 and section.timeout > 0 then
            local fill_frac = math.min(1.0, #section.inputs / section.timeout)
            local bar_color = fill_frac >= 1.0 and '#00FF88AA' or '#4488FFAA'
            BreitbandGraphics.fill_rectangle({
                x = section_rect.x,
                y = section_rect.y,
                width = math.floor(section_rect.width * fill_frac),
                height = 2,
            }, bar_color)
        end

        -- Timeout mismatch: right-edge orange strip when timeout < inputs (unreachable frames)
        if input_sub_index == 1 and section.timeout < #section.inputs then
            BreitbandGraphics.fill_rectangle({
                x = section_rect.x + section_rect.width - 3,
                y = section_rect.y,
                width = 3,
                height = section_rect.height,
            }, '#FF8800DD')
        end

        -- draw buttons
        local unit = Settings.grid_size * Drawing.scale
        local sz = BUTTON_SIZE * unit
        local rect = {
            x = 0,
            y = section_rect.y + (FRAME_COLUMN_HEIGHT - BUTTON_SIZE) * 0.5 * unit,
            width = sz,
            height = sz,
        }
        for button_index, v in ipairs(BUTTONS) do
            rect.x = button_draw_data[button_index].x + unit * (BUTTON_COLUMN_WIDTH - BUTTON_SIZE) * 0.5
            if input.joy[v.input] then
                BreitbandGraphics.fill_ellipse(rect, BUTTON_COLORS[button_draw_data[button_index].color_index].button)
            end
            BreitbandGraphics.draw_ellipse(rect, input.joy[v.input] and '#000000FF' or '#00000050', 1)
        end

        if section_index == sheet.preview_frame.section_index and sheet.preview_frame.frame_index == input_sub_index then
            -- Preview frame: thick red left bar + outline
            BreitbandGraphics.fill_rectangle({ x = section_rect.x, y = section_rect.y, width = 3, height = section_rect.height }, '#FF2020FF')
            BreitbandGraphics.draw_rectangle(section_rect, '#FF2020FF', 1)
        end

        if section_index == sheet.active_frame.section_index and sheet.active_frame.frame_index == input_sub_index then
            -- Active (editing) frame: thick green left bar + outline
            BreitbandGraphics.fill_rectangle({ x = section_rect.x, y = section_rect.y, width = 3, height = section_rect.height }, '#44FF44FF')
            BreitbandGraphics.draw_rectangle(section_rect, '#44FF44FF', 2)
        end

        section_rect.y = section_rect.y + section_rect.height
    end)
end

--#endregion

function __impl.render(draw)
    -- no override queue to drain
    local current_sheet = SemanticWorkflowProject:asserted_current()

    local num_rows = iterate_input_rows(SemanticWorkflowProject:asserted_current(), nil)

    -- Auto-scroll to keep the active frame visible whenever it changes.
    local af = current_sheet.active_frame
    if af.section_index ~= last_active_section or af.frame_index ~= last_active_frame_idx then
        last_active_section = af.section_index
        last_active_frame_idx = af.frame_index
        local target_row = compute_row_of(current_sheet, af.section_index, af.frame_index)
        if target_row <= scroll_offset or target_row > scroll_offset + MAX_DISPLAYED_SECTIONS then
            scroll_offset = math.max(0, math.min(
                math.max(0, num_rows - MAX_DISPLAYED_SECTIONS),
                target_row - math.floor(MAX_DISPLAYED_SECTIONS / 2)
            ))
        end
    end

    local baseline, scrollbar_rect = draw_scrollbar(num_rows)
    local button_draw_data = draw_color_codes(baseline, scrollbar_rect, math.min(num_rows, MAX_DISPLAYED_SECTIONS)) or
        nil
    draw_headers(current_sheet, draw, __impl.view_index, button_draw_data)

    local section_rect = grid_rect(COL0, ROW2, COL_1 - COL0 - SCROLLBAR_WIDTH, FRAME_COLUMN_HEIGHT, 0)
    if handle_scroll_and_buttons(section_rect, button_draw_data, num_rows) then
        current_sheet:run_to_preview()
    end

    draw_sections_gui(current_sheet, draw, __impl.view_index, section_rect, button_draw_data)
end
