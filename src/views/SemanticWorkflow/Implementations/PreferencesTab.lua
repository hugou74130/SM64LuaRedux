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
        ClearColorTags = enum_next(),
        ClearLabels = enum_next(),
        DeselectAll = enum_next(),
        UnlockAll = enum_next(),
        CollapseLocked = enum_next(),
        ClearTemplates = enum_next(),
        TemplateDelete = enum_next(10), -- up to 10 delete buttons for templates
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

    if ugui.button({
            uid = UID.ClearColorTags,
            rectangle = grid_rect(0, top + Gui.MEDIUM_CONTROL_HEIGHT * 5, 4, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_CLEAR_COLOR_TAGS'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_CLEAR_COLOR_TAGS_TOOL_TIP'),
            is_enabled = sheet ~= nil,
        }) then
        if sheet then
            sheet:push_undo_state()
            for _, section in ipairs(sheet.sections) do section.color_tag = nil end
            SemanticWorkflowProject.dirty = true
        end
    end

    if ugui.button({
            uid = UID.ClearLabels,
            rectangle = grid_rect(4, top + Gui.MEDIUM_CONTROL_HEIGHT * 5, 4, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_CLEAR_LABELS'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_CLEAR_LABELS_TOOL_TIP'),
            is_enabled = sheet ~= nil,
        }) then
        if sheet then
            sheet:push_undo_state()
            for _, section in ipairs(sheet.sections) do section.label = nil end
            SemanticWorkflowProject.dirty = true
        end
    end

    if ugui.button({
            uid = UID.DeselectAll,
            rectangle = grid_rect(0, top + Gui.MEDIUM_CONTROL_HEIGHT * 6, 4, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_DESELECT_ALL'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_DESELECT_ALL_TOOL_TIP'),
            is_enabled = sheet ~= nil,
        }) then
        if sheet then
            for _, section in ipairs(sheet.sections) do
                for _, inp in ipairs(section.inputs) do inp.editing = false end
            end
        end
    end

    if ugui.button({
            uid = UID.UnlockAll,
            rectangle = grid_rect(4, top + Gui.MEDIUM_CONTROL_HEIGHT * 6, 4, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_UNLOCK_ALL'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_UNLOCK_ALL_TOOL_TIP'),
            is_enabled = sheet ~= nil,
        }) then
        if sheet then
            sheet:push_undo_state()
            for _, section in ipairs(sheet.sections) do section.locked = nil end
            SemanticWorkflowProject.dirty = true
        end
    end

    if ugui.button({
            uid = UID.CollapseLocked,
            rectangle = grid_rect(0, top + Gui.MEDIUM_CONTROL_HEIGHT * 7, 8, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_COLLAPSE_LOCKED'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_COLLAPSE_LOCKED_TOOL_TIP'),
            is_enabled = sheet ~= nil,
        }) then
        if sheet then
            for _, section in ipairs(sheet.sections) do
                if section.locked and #section.inputs > 1 then section.collapsed = true end
            end
            SemanticWorkflowProject.dirty = true
        end
    end

    -- Sheet statistics display
    if sheet then
        local total_inputs, total_timeout = 0, 0
        for _, sec in ipairs(sheet.sections) do
            total_inputs = total_inputs + #sec.inputs
            total_timeout = total_timeout + sec.timeout
        end
        draw:small_text(
            grid_rect(0, top + Gui.MEDIUM_CONTROL_HEIGHT * 8, 8, Gui.MEDIUM_CONTROL_HEIGHT),
            'start',
            string.format('%d secs  %d/%d frames  ~%.1fs @ 30fps',
                #sheet.sections, total_inputs, total_timeout, total_timeout / 30)
        )
    end

    -- Section templates management
    local templates = Settings.semantic_workflow.section_templates
    local trow = top + Gui.MEDIUM_CONTROL_HEIGHT * 9
    draw:small_text(
        grid_rect(0, trow, 6, Gui.SMALL_CONTROL_HEIGHT),
        'start',
        Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_TEMPLATES') .. ' (' .. #templates .. ')'
    )
    if ugui.button({
            uid = UID.ClearTemplates,
            rectangle = grid_rect(6, trow, 2, Gui.SMALL_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_CLEAR_TEMPLATES'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PREFERENCES_CLEAR_TEMPLATES_TOOL_TIP'),
            is_enabled = #templates > 0,
        }) then
        Settings.semantic_workflow.section_templates = {}
    end
    for ti = 1, math.min(10, #templates) do
        local tpl = templates[ti]
        local ty = trow + ti * Gui.SMALL_CONTROL_HEIGHT
        draw:small_text(grid_rect(0, ty, 6.5, Gui.SMALL_CONTROL_HEIGHT), 'start', ti .. '. ' .. tpl.name)
        if ugui.button({
                uid = UID.TemplateDelete + (ti - 1),
                rectangle = grid_rect(6.5, ty, 1.5, Gui.SMALL_CONTROL_HEIGHT),
                text = 'del',
            }) then
            table.remove(templates, ti)
        end
    end
end
