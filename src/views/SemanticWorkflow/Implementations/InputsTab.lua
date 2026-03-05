--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

---@type InputsTab
---@diagnostic disable-next-line: assign-type-mismatch
local __impl = __impl

__impl.name = 'Inputs'
__impl.help_key = 'INPUTS_TAB'

---@type FrameListGui
local FrameListGui = dofile(views_path .. 'SemanticWorkflow/Definitions/FrameListGui.lua')

---@type Section
local Section = dofile(views_path .. 'SemanticWorkflow/Definitions/Section.lua')

---@type Gui
local Gui = dofile(views_path .. 'SemanticWorkflow/Definitions/Gui.lua')

--#region Constants

local LABEL_HEIGHT <const> = 0.25

local TOP <const> = 10.25
local MAX_ACTION_GUESSES <const> = 5

--#endregion

--#region Logic

local selected_view_index = 1

local previous_preview_frame
local atan_start = 0

local UID = UIDProvider.allocate_once(__impl.name, function(enum_next)
    return {
        ViewCarrousel = enum_next(),
        InsertInput = enum_next(),
        DeleteInput = enum_next(),
        InsertSection = enum_next(),
        DeleteSection = enum_next(),

        -- Joystick Controls
        Joypad = enum_next(),
        JoypadSpinnerX = enum_next(4),
        JoypadSpinnerY = enum_next(4),
        GoalAngle = enum_next(2),
        GoalMag = enum_next(2),
        HighMag = enum_next(),
        StrainLeft = enum_next(),
        StrainRight = enum_next(),
        StrainAlways = enum_next(),
        StrainSpeedTarget = enum_next(),
        MovementModeManual = enum_next(),
        MovementModeMatchYaw = enum_next(),
        MovementModeMatchAngle = enum_next(),
        MovementModeReverseYaw = enum_next(),
        DYaw = enum_next(),
        Atan = enum_next(),
        AtanReverse = enum_next(),
        AtanRetime = enum_next(),
        AtanN = enum_next(4),
        AtanD = enum_next(4),
        AtanS = enum_next(4),
        AtanE = enum_next(4),
        SpeedKick = enum_next(),
        ResetMag = enum_next(),
        Swim = enum_next(),

        -- Section Controls
        Kind = enum_next(),
        Timeout = enum_next(2),
        EndAction = enum_next(),
        EndActionTextbox = enum_next(),
        AvailableActions = enum_next(MAX_ACTION_GUESSES),
        SectionLabel = enum_next(),
        CollapseAll = enum_next(),
        ExpandAll = enum_next(),

        -- Structural undo/redo
        Undo = enum_next(),
        Redo = enum_next(),

        -- Section automation
        MoveSectionUp = enum_next(),
        MoveSectionDown = enum_next(),
        CopySection = enum_next(),
        PasteSection = enum_next(),
        RepeatN = enum_next(2),
        RepeatInput = enum_next(),
    }
end)

local function any_entries(table)
    for _ in pairs(table) do return true end
    return false
end

--#region Insert and remove

local function controls_for_insert_and_remove()
    local sheet = SemanticWorkflowProject:asserted_current()
    local edited_section = sheet.sections[sheet.active_frame.section_index]
    local edited_input = edited_section and edited_section.inputs[sheet.active_frame.frame_index] or nil
    local any_changes = false

    local top = TOP
    if ugui.button({
            uid = UID.InsertInput,
            rectangle = grid_rect(0, top, 1, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_INSERT_INPUT'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_INSERT_INPUT_TOOL_TIP'),
        }) then
        sheet:push_undo_state()
        table.insert(edited_section.inputs, sheet.active_frame.frame_index, ugui.internal.deep_clone(edited_input))
        edited_section.collapsed = false
        any_changes = true
    end

    if ugui.button({
            uid = UID.DeleteInput,
            rectangle = grid_rect(1, top, 1, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_DELETE_INPUT'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_DELETE_INPUT_TOOL_TIP'),
            is_enabled = #edited_section.inputs > 1,
        }) then
        sheet:push_undo_state()
        table.remove(edited_section.inputs, sheet.active_frame.frame_index)
        any_changes = true
    end

    if ugui.button({
            uid = UID.InsertSection,
            rectangle = grid_rect(2, top, 1, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_INSERT_SECTION'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_INSERT_SECTION_TOOL_TIP'),
        }) then
        sheet:push_undo_state()
        local new_section = Section.new(0x0C400201, Settings.semantic_workflow.default_section_timeout) -- end action is "idle"
        table.insert(sheet.sections, sheet.active_frame.section_index + 1, new_section)
        any_changes = true
    end

    if ugui.button({
            uid = UID.DeleteSection,
            rectangle = grid_rect(3, top, 1, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_DELETE_SECTION'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_DELETE_SECTION_TOOL_TIP'),
            is_enabled = #sheet.sections > 1,
        }) then
        sheet:push_undo_state()
        table.remove(sheet.sections, sheet.active_frame.section_index)
        any_changes = true
    end

    if ugui.button({
            uid = UID.Undo,
            rectangle = grid_rect(4, top, 1, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_UNDO'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_UNDO_TOOL_TIP'),
            is_enabled = #sheet._undo_stack > 0,
        }) then
        sheet:undo()
    end

    if ugui.button({
            uid = UID.Redo,
            rectangle = grid_rect(5, top, 1, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_REDO'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_REDO_TOOL_TIP'),
            is_enabled = #sheet._redo_stack > 0,
        }) then
        sheet:redo()
    end

    -- ensure a valid selection in all cases
    sheet.active_frame.section_index = math.min(
        sheet.active_frame.section_index,
        #sheet.sections
    )
    sheet.active_frame.frame_index = math.min(
        sheet.active_frame.frame_index,
        #sheet.sections[sheet.active_frame.section_index].inputs
    )

    if any_changes then
        sheet:run_to_preview()
    end
end

--#endregion

--#region Section controls

local end_action_search_text = nil
local clipboard_section = nil  -- section clipboard for copy/paste
local repeat_count = 1         -- frame repeat count (×N button)

-- mapping used when the end-action control should auto‑fill a button press
-- on the currently selected input. kept small to avoid duplication with
-- FrameListGui; expand if more actions need propagation.
-- common one‑frame mappings; long jump needs special handling because
-- it is executed across two inputs (hold Z then press A).  The UI will
-- set the previous frame’s Z and the current frame’s A when an end action
-- of long jump is chosen.
local END_ACTION_JOYMAP = {
    [0x03000880] = { A = true },            -- single jump
    [0x008008A9] = { Z = true },            -- ground pound
    [0x18008AA] = { Z = true, B = true },   -- slide kick
    [0x0188088A] = { B = true },            -- air dive
    [0x00880456] = { A = true, B = true },  -- ground dive
    [0x18008AC] = { A = true, B = true },   -- air kick
}

local function controls_for_end_action(section, edited_input, draw, column, top)
    local changed = false
    draw:text(grid_rect(column, top, 4, LABEL_HEIGHT), 'start', Locales.str('SEMANTIC_WORKFLOW_INPUTS_END_ACTION'))
    if end_action_search_text == nil then
        -- end action "dropdown" is not visible
        if ugui.button({
                uid = UID.EndAction,
                rectangle = grid_rect(column, top + LABEL_HEIGHT, 4, Gui.MEDIUM_CONTROL_HEIGHT),
                text = Locales.action(section.end_action),
                tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_END_ACTION_TOOL_TIP'),
            }) then
            end_action_search_text = ''
            ugui.internal.active_control = UID.EndActionTextbox
            ugui.internal.clear_active_control_after_mouse_up = false
        end
    end
    if end_action_search_text ~= nil then
        -- end action "dropdown" is visible
        end_action_search_text = ugui.textbox({
            uid = UID.EndActionTextbox,
            rectangle = grid_rect(column, top + LABEL_HEIGHT, 4, Gui.MEDIUM_CONTROL_HEIGHT),
            text = end_action_search_text,
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_END_ACTION_TYPE_TO_SEARCH_TOOL_TIP'),
        }):lower()
        local i = 0
        for action, action_name in pairs(Locales.raw().ACTIONS) do
            if action_name:find(end_action_search_text, 1, true) ~= nil then
                if ugui.button({
                        uid = UID.AvailableActions + i,
                        rectangle = grid_rect(column, top + LABEL_HEIGHT + Gui.MEDIUM_CONTROL_HEIGHT + i * Gui.SMALL_CONTROL_HEIGHT, 4, Gui.SMALL_CONTROL_HEIGHT),
                        text = action_name,
                    }) then
                    end_action_search_text = nil
                    section.end_action = action
                    changed = true

                    -- if an input is currently being edited, apply the corresponding
                    -- button pattern so that the row shows a press immediately.
                    -- apply button pattern into the section inputs. regardless of
                    -- whether a specific row is being edited, always append the
                    -- long‑jump sequence at the end of the section when that
                    -- action is selected; this guarantees the four frames appear.
                    if action == 0x03000888 then
                        local pattern = {
                            { Z = true },
                            { Z = true },
                            { A = true },
                            { A = true },
                        }

                        -- determine insertion point: prefer the currently edited frame,
                        -- otherwise the sheet's active_frame, fall back to end.
                        local sheet = SemanticWorkflowProject:asserted_current()
                        local start_idx = nil
                        if edited_input then
                            -- find edited_input's index
                            for i,v in ipairs(section.inputs) do
                                if v == edited_input then
                                    start_idx = i
                                    break
                                end
                            end
                        end
                        if not start_idx and sheet and sheet.active_frame then
                            local sec = sheet.sections[sheet.active_frame.section_index]
                            if sec == section then
                                start_idx = sheet.active_frame.frame_index
                            end
                        end
                        start_idx = start_idx or (#section.inputs + 1)

                        -- insert pattern starting at start_idx
                        for i, joy in ipairs(pattern) do
                            local idx = start_idx + i - 1
                            while #section.inputs < idx do
                                local tmp = {}
                                CloneInto(tmp, Joypad.input)
                                table.insert(section.inputs, { tas_state = NewTASState(), joy = tmp })
                            end
                            section.inputs[idx].joy = ugui.internal.deep_clone(joy)
                        end

                    elseif edited_input and END_ACTION_JOYMAP[action] then
                        edited_input.joy = ugui.internal.deep_clone(END_ACTION_JOYMAP[action])
                    end
                end

                i = i + 1
                if (i >= MAX_ACTION_GUESSES) then break end
            end
        end
    end
    return changed
end

local function section_controls_for_selected(draw, edited_section, edited_input)
    local sheet = SemanticWorkflowProject:asserted_current()

    local top = TOP
    local col_timeout = 4

    local any_changes = false

    if edited_section == nil then return end

    top = top + 1

    draw:text(grid_rect(col_timeout, top, 2, LABEL_HEIGHT), 'start', Locales.str('SEMANTIC_WORKFLOW_INPUTS_TIMEOUT'))
    local old_timeout = edited_section.timeout
    edited_section.timeout = ugui.numberbox({
        uid = UID.Timeout,
        rectangle = grid_rect(col_timeout, top + LABEL_HEIGHT, 2, Gui.MEDIUM_CONTROL_HEIGHT),
        value = edited_section.timeout,
        places = 4,
        tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_TIMEOUT_TOOL_TIP'),
    })
    any_changes = any_changes or old_timeout ~= edited_section.timeout

    any_changes = any_changes or controls_for_end_action(edited_section, edited_input, draw, 0, top)

    if any_changes then
        sheet:run_to_preview()
    end

    -- Collapse All / Expand All (always visible when a section is selected)
    if ugui.button({
            uid = UID.CollapseAll,
            rectangle = grid_rect(6, top, 1, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_COLLAPSE_ALL'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_COLLAPSE_ALL_TOOL_TIP'),
        }) then
        for _, section in ipairs(sheet.sections) do
            if #section.inputs > 1 then section.collapsed = true end
        end
        SemanticWorkflowProject.dirty = true
    end

    if ugui.button({
            uid = UID.ExpandAll,
            rectangle = grid_rect(7, top, 1, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_EXPAND_ALL'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_EXPAND_ALL_TOOL_TIP'),
        }) then
        for _, section in ipairs(sheet.sections) do
            section.collapsed = false
        end
        SemanticWorkflowProject.dirty = true
    end

    -- Section label
    draw:text(
        grid_rect(col_timeout, top + LABEL_HEIGHT + Gui.MEDIUM_CONTROL_HEIGHT, 2, LABEL_HEIGHT),
        'start',
        Locales.str('SEMANTIC_WORKFLOW_INPUTS_SECTION_LABEL')
    )
    local old_label = edited_section.label or ''
    local new_label = ugui.textbox({
        uid = UID.SectionLabel,
        rectangle = grid_rect(col_timeout, top + LABEL_HEIGHT + Gui.MEDIUM_CONTROL_HEIGHT + LABEL_HEIGHT, 2, Gui.MEDIUM_CONTROL_HEIGHT),
        text = old_label,
        tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_SECTION_LABEL_TOOL_TIP'),
    })
    if new_label ~= old_label then
        edited_section.label = new_label ~= '' and new_label or nil
        SemanticWorkflowProject.dirty = true
    end

    -- ── Section automation ────────────────────────────────────────────────
    -- Two compact rows placed below the label textbox.
    local section_idx = sheet.active_frame.section_index
    local auto_row1 = top + 2 * LABEL_HEIGHT + 2 * Gui.MEDIUM_CONTROL_HEIGHT
    local auto_row2 = auto_row1 + Gui.SMALL_CONTROL_HEIGHT

    -- Row 1: move up/down, copy, paste
    if ugui.button({
            uid = UID.MoveSectionUp,
            rectangle = grid_rect(0, auto_row1, 1, Gui.SMALL_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_SECTION_MOVE_UP'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_SECTION_MOVE_UP_TOOL_TIP'),
            is_enabled = section_idx > 1,
        }) then
        sheet:push_undo_state()
        sheet.sections[section_idx], sheet.sections[section_idx - 1] =
            sheet.sections[section_idx - 1], sheet.sections[section_idx]
        sheet.active_frame.section_index = section_idx - 1
        sheet:run_to_preview()
    end

    if ugui.button({
            uid = UID.MoveSectionDown,
            rectangle = grid_rect(1, auto_row1, 1, Gui.SMALL_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_SECTION_MOVE_DOWN'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_SECTION_MOVE_DOWN_TOOL_TIP'),
            is_enabled = section_idx < #sheet.sections,
        }) then
        sheet:push_undo_state()
        sheet.sections[section_idx], sheet.sections[section_idx + 1] =
            sheet.sections[section_idx + 1], sheet.sections[section_idx]
        sheet.active_frame.section_index = section_idx + 1
        sheet:run_to_preview()
    end

    if ugui.button({
            uid = UID.CopySection,
            rectangle = grid_rect(2, auto_row1, 2, Gui.SMALL_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_SECTION_COPY'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_SECTION_COPY_TOOL_TIP'),
        }) then
        clipboard_section = ugui.internal.deep_clone(edited_section)
    end

    if ugui.button({
            uid = UID.PasteSection,
            rectangle = grid_rect(4, auto_row1, 2, Gui.SMALL_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_SECTION_PASTE'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_SECTION_PASTE_TOOL_TIP'),
            is_enabled = clipboard_section ~= nil,
        }) then
        if clipboard_section == nil then return end  -- is_enabled already guards this; nil-check for type safety
        sheet:push_undo_state()
        table.insert(sheet.sections, section_idx + 1, ugui.internal.deep_clone(clipboard_section))
        sheet.active_frame.section_index = section_idx + 1
        sheet:run_to_preview()
    end

    -- Row 2: frame repeat (×N)
    draw:text(
        grid_rect(0, auto_row2, 3, Gui.SMALL_CONTROL_HEIGHT),
        'start',
        Locales.str('SEMANTIC_WORKFLOW_INPUTS_REPEAT_N')
    )
    repeat_count = ugui.numberbox({
        uid = UID.RepeatN,
        rectangle = grid_rect(3, auto_row2, 2, Gui.SMALL_CONTROL_HEIGHT),
        value = repeat_count,
        places = 3,
    })
    if repeat_count < 1 or repeat_count >= 900 then repeat_count = 1 end

    if ugui.button({
            uid = UID.RepeatInput,
            rectangle = grid_rect(5, auto_row2, 3, Gui.SMALL_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_INPUTS_REPEAT_INPUT'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_INPUTS_REPEAT_INPUT_TOOL_TIP'),
        }) then
        sheet:push_undo_state()
        local frame_idx = sheet.active_frame.frame_index
        local template = ugui.internal.deep_clone(edited_section.inputs[frame_idx])
        for i = 1, repeat_count do
            table.insert(edited_section.inputs, frame_idx + i, ugui.internal.deep_clone(template))
        end
        edited_section.collapsed = false
        sheet:run_to_preview()
    end
end

--#endregion

--#region Joystick Controls

local function magnitude_controls(draw, sheet, new_values, top)
    new_values.high_magnitude = ugui.toggle_button({
        uid = UID.HighMag,
        rectangle = grid_rect(2, top, 2, Gui.MEDIUM_CONTROL_HEIGHT),
        text = Locales.str('SEMANTIC_WORKFLOW_CONTROL_HIGH_MAG'),
        is_checked = new_values.high_magnitude,
    })
    new_values.goal_mag = ugui.numberbox({
        uid = UID.GoalMag,
        rectangle = grid_rect(4, top, 1.5, Gui.MEDIUM_CONTROL_HEIGHT),
        places = 3,
        value = math.max(0, math.min(127, new_values.goal_mag)),
    })
    -- a value starting with a 9 likely indicates that the user scrolled down
    -- on the most significant digit while its value was 0, so we "clamp" to 0 here
    -- this makes it so typing in a 9 explicitly will set the entire value to 0 as well,
    -- but I'll accept this weirdness for now until a more coherently bounded numberbox implementation exists.
    if new_values.goal_mag >= 900 then new_values.goal_mag = 0 end

    if ugui.button({
            uid = UID.SpeedKick,
            rectangle = grid_rect(5.5, top, 1.5, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_CONTROL_SPDKICK'),
        }) then
        if new_values.goal_mag ~= 48 then
            new_values.goal_mag = 48
        else
            new_values.goal_mag = 127
        end
    end

    if ugui.button({
            uid = UID.ResetMag,
            rectangle = grid_rect(7, top, 1, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('MAG_RESET'),
        }) then
        new_values.goal_mag = 127
    end
end

local function noop() end

local function select_atan_end(selection_frame)
    local sheet = SemanticWorkflowProject:asserted_current()
    sheet.preview_frame = selection_frame
    sheet:run_to_preview()
    FrameListGui.special_select_handler = noop
end

local function select_atan_start(selection_frame)
    print(selection_frame)
    local sheet = SemanticWorkflowProject:asserted_current()
    previous_preview_frame = sheet.preview_frame
    sheet.preview_frame = selection_frame
    sheet:run_to_preview()
    FrameListGui.special_select_handler = select_atan_end
end

local function atan_controls(draw, sheet, new_values, top)
    draw:text(grid_rect(0, top, 1, Gui.MEDIUM_CONTROL_HEIGHT), 'start', 'Atan:')

    if not sheet.busy then
        if FrameListGui.special_select_handler == select_atan_end then
            atan_start = Memory.current.mario_global_timer - 1
        elseif FrameListGui.special_select_handler == noop then
            local atan_end = Memory.current.mario_global_timer
            new_values.atan_start = atan_start
            new_values.atan_n = atan_end - atan_start
            sheet.preview_frame = previous_preview_frame
            FrameListGui.special_select_handler = nil
            any_changes = true
        end
    end

    local new_atan = ugui.toggle_button({
        uid = UID.Atan,
        rectangle = grid_rect(1, top, 1.5, Gui.MEDIUM_CONTROL_HEIGHT),
        text = Locales.str('SEMANTIC_WORKFLOW_CONTROL_ATAN'),
        is_checked = new_values.atan_strain,
    })
    if new_atan and not new_values.atan_strain then
        new_values.movement_mode = MovementModes.match_angle
    end
    new_values.atan_strain = new_atan

    local atan_retime_state =
        FrameListGui.special_select_handler == select_atan_start and 'SEMANTIC_WORKFLOW_CONTROL_ATAN_SELECT_START'
        or FrameListGui.special_select_handler == select_atan_end and 'SEMANTIC_WORKFLOW_CONTROL_ATAN_SELECT_END'
        or 'SEMANTIC_WORKFLOW_CONTROL_ATAN_RETIME'
    if ugui.button({
            uid = UID.AtanRetime,
            rectangle = grid_rect(2.5, top, 2.5, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str(atan_retime_state),
            is_enabled = FrameListGui.special_select_handler == nil,
        }) then
        FrameListGui.special_select_handler = select_atan_start
    end

    local label_offset = -0.5
    top = top + Gui.MEDIUM_CONTROL_HEIGHT + 0.25

    draw:text(grid_rect(0, top + label_offset, 0.75, Gui.MEDIUM_CONTROL_HEIGHT), 'start', 'N:')
    new_values.atan_n = ugui.spinner({
        uid = UID.AtanN,
        rectangle = grid_rect(0, top, 1.25, Gui.MEDIUM_CONTROL_HEIGHT),
        value = new_values.atan_n,
        minimum_value = 1,
        maximum_value = 4000,
        increment = math.max(0.25, math.pow(10, Settings.atan_exp)),
    })

    draw:text(grid_rect(1.25, top + label_offset, 0.75, Gui.MEDIUM_CONTROL_HEIGHT), 'start', 'D:')
    new_values.atan_d = ugui.spinner({
        uid = UID.AtanD,
        rectangle = grid_rect(1.25, top, 1.75, Gui.MEDIUM_CONTROL_HEIGHT),
        value = new_values.atan_d,
        minimum_value = -1000000,
        maximum_value = 1000000,
        increment = math.pow(10, Settings.atan_exp),
    })

    draw:text(grid_rect(3, top + label_offset, 2.35, Gui.MEDIUM_CONTROL_HEIGHT), 'start', 'Start:')
    new_values.atan_start = ugui.spinner({
        uid = UID.AtanS,
        rectangle = grid_rect(3, top, 2.35, Gui.MEDIUM_CONTROL_HEIGHT),
        value = new_values.atan_start,
        minimum_value = 0,
        maximum_value = 0xFFFFFFFF,
        increment = math.pow(10, Settings.atan_exp),
    })

    draw:text(grid_rect(5.5, top + label_offset, 0.5, Gui.MEDIUM_CONTROL_HEIGHT), 'start', 'E:')
    Settings.atan_exp = ugui.spinner({
        uid = UID.AtanE,
        rectangle = grid_rect(5.5, top, 1, Gui.MEDIUM_CONTROL_HEIGHT),
        value = Settings.atan_exp,
        minimum_value = -9,
        maximum_value = 5,
        increment = 1,
    })

    new_values.reverse_arc = ugui.toggle_button({
        uid = UID.AtanReverse,
        rectangle = grid_rect(6.5, top, 1.5, Gui.MEDIUM_CONTROL_HEIGHT),
        text = Locales.str('SEMANTIC_WORKFLOW_CONTROL_ATAN_REVERSE'),
        is_checked = new_values.reverse_arc,
    })
end

local function joystick_controls_for_selected(draw, edited_section, edited_input)
    local top = TOP

    local sheet = SemanticWorkflowProject:asserted_current()

    local new_values = {}

    local old_values = edited_input.tas_state
    CloneInto(new_values, old_values)

    local display_position = { x = old_values.manual_joystick_x or 0, y = -(old_values.manual_joystick_y or 0) }
    local new_position, meta = ugui.joystick({
        uid = UID.Joypad,
        rectangle = grid_rect(0, top + 1, 2, 2),
        position = display_position,
    })
    if meta.signal_change == ugui.signal_change_states.started then
        new_values.movement_mode = MovementModes.manual
        new_values.manual_joystick_x = math.min(127, math.floor(new_position.x + 0.5)) or old_values.manual_joystick_x
        new_values.manual_joystick_y = math.min(127, -math.floor(new_position.y + 0.5)) or old_values.manual_joystick_y
    end
    local rect = grid_rect(0, top + 3, 1, Gui.SMALL_CONTROL_HEIGHT, 0)
    rect.y = rect.y + Settings.grid_gap
    new_values.manual_joystick_x = ugui.spinner({
        uid = UID.JoypadSpinnerX,
        rectangle = rect,
        value = new_values.manual_joystick_x,
        minimum_value = -128,
        maximum_value = 127,
        increment = 1,
        styler_mixin = {
            spinner = {
                button_size = 4,
            },
        },
    })
    rect.x = rect.x + rect.width
    new_values.manual_joystick_y = ugui.spinner({
        uid = UID.JoypadSpinnerY,
        rectangle = rect,
        value = new_values.manual_joystick_y,
        minimum_value = -128,
        maximum_value = 127,
        increment = 1,
        styler_mixin = {
            spinner = {
                button_size = 4,
            },
        },
    })

    new_values.goal_angle = math.abs(ugui.numberbox({
        uid = UID.GoalAngle,
        is_enabled = new_values.movement_mode == MovementModes.match_angle,
        rectangle = grid_rect(3, top + 2, 2, Gui.LARGE_CONTROL_HEIGHT),
        places = 5,
        value = new_values.goal_angle,
    }))

    new_values.strain_always = ugui.toggle_button({
        uid = UID.StrainAlways,
        rectangle = grid_rect(2, top + 1, 1.5, Gui.SMALL_CONTROL_HEIGHT),
        text = Locales.str('D99_ALWAYS'),
        is_checked = new_values.strain_always,
    })

    new_values.strain_speed_target = ugui.toggle_button({
        uid = UID.StrainSpeedTarget,
        rectangle = grid_rect(3.5, top + 1, 1.5, Gui.SMALL_CONTROL_HEIGHT),
        text = Locales.str('D99'),
        is_checked = new_values.strain_speed_target,
    })

    if ugui.toggle_button({
            uid = UID.StrainLeft,
            rectangle = grid_rect(2, top + 1.5, 1.5, Gui.SMALL_CONTROL_HEIGHT),
            text = '[icon:arrow_left]',
            is_checked = new_values.strain_left,
        }) then
        new_values.strain_right = false
        new_values.strain_left = true
    else
        new_values.strain_left = false
    end

    if ugui.toggle_button({
            uid = UID.StrainRight,
            rectangle = grid_rect(3.5, top + 1.5, 1.5, Gui.SMALL_CONTROL_HEIGHT),
            text = '[icon:arrow_right]',
            is_checked = new_values.strain_right,
        }) then
        new_values.strain_left = false
        new_values.strain_right = true
    else
        new_values.strain_right = false
    end

    if ugui.toggle_button({
            uid = UID.MovementModeManual,
            rectangle = grid_rect(5, top + 1, 1.5, Gui.LARGE_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_CONTROL_MANUAL'),
            is_checked = new_values.movement_mode == MovementModes.manual,
        }) then
        new_values.movement_mode = MovementModes.manual
    end

    if ugui.toggle_button({
            uid = UID.MovementModeMatchYaw,
            rectangle = grid_rect(6.5, top + 1, 1.5, Gui.LARGE_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_CONTROL_MATCH_YAW'),
            is_checked = new_values.movement_mode == MovementModes.match_yaw,
        }) then
        new_values.movement_mode = MovementModes.match_yaw
    end

    if ugui.toggle_button({
            uid = UID.MovementModeMatchAngle,
            rectangle = grid_rect(5, top + 2, 1.5, Gui.LARGE_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_CONTROL_MATCH_ANGLE'),
            is_checked = new_values.movement_mode == MovementModes.match_angle,
        }) then
        new_values.movement_mode = MovementModes.match_angle
    end

    if ugui.toggle_button({
            uid = UID.MovementModeReverseYaw,
            rectangle = grid_rect(6.5, top + 2, 1.5, Gui.LARGE_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_CONTROL_REVERSE_YAW'),
            is_checked = new_values.movement_mode == MovementModes.reverse_yaw,
        }) then
        new_values.movement_mode = MovementModes.reverse_yaw
    end

    new_values.dyaw = ugui.toggle_button({
        uid = UID.DYaw,
        rectangle = grid_rect(2, top + 2, 1, Gui.LARGE_CONTROL_HEIGHT),
        text = Locales.str('SEMANTIC_WORKFLOW_CONTROL_DYAW'),
        is_checked = new_values.dyaw,
    })

    new_values.swim = ugui.toggle_button({
        uid = UID.Swim,
        rectangle = grid_rect(6.5, top + 4, 1.5, Gui.MEDIUM_CONTROL_HEIGHT),
        text = 'Swim',
        is_checked = new_values.swim,
    })

    magnitude_controls(draw, sheet, new_values, top + 3)
    atan_controls(draw, sheet, new_values, top + 4)

    local changes = CloneInto(old_values, new_values)
    local any_changes = any_entries(changes)
    local current_sheet = SemanticWorkflowProject:asserted_current()
    if any_changes and edited_input then
        for _, section in pairs(sheet.sections) do
            for _, input in pairs(section.inputs) do
                if input.editing then
                    CloneInto(input.tas_state, Settings.semantic_workflow.edit_entire_state and old_values or changes)
                end
            end
        end
    end

    if any_changes then
        current_sheet:run_to_preview()
    end
end

--#endregion

--#endregion

function __impl.render(draw)
    local sheet = SemanticWorkflowProject:asserted_current()
    local edited_section = sheet.sections[sheet.active_frame.section_index]
    local edited_input = edited_section and edited_section.inputs[sheet.active_frame.frame_index] or nil

    FrameListGui.view_index = selected_view_index
    FrameListGui.render(draw)

    local draw_funcs = { joystick_controls_for_selected, section_controls_for_selected }
    selected_view_index = ugui.carrousel_button({
        uid = UID.ViewCarrousel,
        rectangle = grid_rect(6, TOP, 2, Gui.MEDIUM_CONTROL_HEIGHT),
        value = selected_view_index,
        items = { 'Joystick', 'Section' },
        selected_index = selected_view_index,
    })

    draw_funcs[selected_view_index](draw, edited_section, edited_input)
    controls_for_insert_and_remove()
end
