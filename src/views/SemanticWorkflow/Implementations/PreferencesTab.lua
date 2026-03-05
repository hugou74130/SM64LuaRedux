--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

---@type PreferencesTab
---@diagnostic disable-next-line: assign-type-mismatch
local __impl = __impl

__impl.name = 'Preferences'
__impl.help_key = 'PREFERENCES_TAB'

---@type Gui
local Gui = dofile(views_path .. 'SemanticWorkflow/Definitions/Gui.lua')

local UID = UIDProvider.allocate_once(__impl.name, function(enum_next)
    return {
        ToggleEditEntireState = enum_next(),
        ToggleFastForward = enum_next(),
        DefaultSectionTimeout = enum_next(2),
        ToggleAutoSave = enum_next(),
        FitAllTimeouts = enum_next(),
    }
end)

function __impl.render(draw)
    local top = 1
    Settings.semantic_workflow.edit_entire_state = ugui.toggle_button(
        {
            uid = UID.ToggleEditEntireState,
            rectangle = grid_rect(0, top, 8, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_EDIT_ENTIRE_STATE'),
            is_checked = Settings.semantic_workflow.edit_entire_state,
        }
    )
    Settings.semantic_workflow.fast_foward = ugui.toggle_button(
        {
            uid = UID.ToggleFastForward,
            rectangle = grid_rect(0, top + Gui.MEDIUM_CONTROL_HEIGHT, 8, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_FAST_FORWARD'),
            is_checked = Settings.semantic_workflow.fast_foward,
        }
    )
    Settings.semantic_workflow.auto_save = ugui.toggle_button(
        {
            uid = UID.ToggleAutoSave,
            rectangle = grid_rect(0, top + Gui.MEDIUM_CONTROL_HEIGHT * 2, 8, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_AUTO_SAVE'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_AUTO_SAVE_TOOL_TIP'),
            is_checked = Settings.semantic_workflow.auto_save,
        }
    )

    draw:text(
        grid_rect(2, top + Gui.MEDIUM_CONTROL_HEIGHT * 3, 4, Gui.MEDIUM_CONTROL_HEIGHT),
        'end',
        Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_DEFAULT_SECTION_TIMEOUT')
    )
    Settings.semantic_workflow.default_section_timeout = math.max(
        ugui.numberbox(
            {
                uid = UID.DefaultSectionTimeout,
                rectangle = grid_rect(6, top + Gui.MEDIUM_CONTROL_HEIGHT * 3, 2, Gui.MEDIUM_CONTROL_HEIGHT),
                places = 3,
                value = Settings.semantic_workflow.default_section_timeout,
            }
        ),
        1
    )

    local sheet = SemanticWorkflowProject and SemanticWorkflowProject:current()
    if ugui.button({
            uid = UID.FitAllTimeouts,
            rectangle = grid_rect(0, top + Gui.MEDIUM_CONTROL_HEIGHT * 4, 8, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_FIT_ALL_TIMEOUTS'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_FIT_ALL_TIMEOUTS_TOOL_TIP'),
            is_enabled = sheet ~= nil,
        }) then
        if sheet then
            sheet:push_undo_state()
            for _, section in ipairs(sheet.sections) do
                section.timeout = #section.inputs
            end
            sheet:run_to_preview()
        end
    end
end
