--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

---@type ProjectTab
---@diagnostic disable-next-line: assign-type-mismatch
local __impl = __impl

__impl.name = 'Project'
__impl.help_key = 'PROJECT_TAB'

---@type Project
local Project = dofile(views_path .. 'SemanticWorkflow/Definitions/Project.lua')

---@type Gui
local Gui = dofile(views_path .. 'SemanticWorkflow/Definitions/Gui.lua')

local UID = UIDProvider.allocate_once(__impl.name, function(enum_next)
    return {
        NewProject = enum_next(),
        OpenProject = enum_next(),
        SaveProject = enum_next(),
        PurgeProject = enum_next(),
        DisableProjectSheets = enum_next(),
        ProjectSheetBase = enum_next(1024),
        AddSheet = enum_next(),
        ConfirmationYes = enum_next(),
        ConfirmationNo = enum_next(),
        CancelDuplicate = enum_next(),
        RecentProjectsBase = enum_next(10),
    }
end)

local function create_confirm_dialog(prompt, on_confirmed)
    return function()
        local top = 15 - Gui.MEDIUM_CONTROL_HEIGHT

        local theme = Styles.theme()

        BreitbandGraphics.draw_text2({
            rectangle = grid_rect(0, top - 8, 8, 8),
            text = prompt,
            align_x = BreitbandGraphics.alignment.center,
            align_y = BreitbandGraphics.alignment['end'],
            color = theme.button.text[1],
            font_size = theme.font_size * 1.2 * Drawing.scale,
            font_name = theme.font_name,
        })

        if ugui.button({
                uid = UID.ConfirmationYes,
                rectangle = grid_rect(4, top, 2, Gui.MEDIUM_CONTROL_HEIGHT),
                text = Locales.str('YES'),
            }) then
            on_confirmed()
            SemanticWorkflowDialog = nil
        end
        if ugui.button({
                uid = UID.ConfirmationNo,
                rectangle = grid_rect(2, top, 2, Gui.MEDIUM_CONTROL_HEIGHT),
                text = Locales.str('NO'),
            }) then
            SemanticWorkflowDialog = nil
        end
    end
end

local function render_confirm_deletion_prompt(sheet_index)
    return create_confirm_dialog(
        Locales.str('SEMANTIC_WORKFLOW_PROJECT_CONFIRM_SHEET_DELETION_1')
        .. SemanticWorkflowProject.meta.sheets[sheet_index].name
        .. Locales.str('SEMANTIC_WORKFLOW_PROJECT_CONFIRM_SHEET_DELETION_2'),
        function() SemanticWorkflowProject:remove_sheet(sheet_index) end
    )
end

local RenderConfirmPurgeDialog = create_confirm_dialog(
    Locales.str('SEMANTIC_WORKFLOW_PROJECT_CONFIRM_PURGE'),
    function()
        local ignored_files = {}
        local project_folder = SemanticWorkflowProject:project_folder()
        for _, sheet_meta in ipairs(SemanticWorkflowProject.meta.sheets) do
            ignored_files[sheet_meta.name .. '.sws'] = true
            ignored_files[sheet_meta.name .. '.sws.savestate'] = true
        end
        local pipe = io.popen('dir \"' .. project_folder .. '\" /b')
        if pipe then
            for file in pipe:lines() do
                if ignored_files[file] == nil and (file:match('(.)sws$') ~= nil or file:match('(.)sws(.)savestate$') ~= nil) then
                    assert(os.remove(project_folder .. file))
                    print('removed ' .. file)
                end
            end
            pipe:close()
        end
    end
)

local selecting_sheet_base_for = nil
local duplicating_sheet_index = nil

local function track_recent(path)
    local recent = Settings.semantic_workflow.recent_projects
    for i = #recent, 1, -1 do
        if recent[i] == path then table.remove(recent, i) end
    end
    table.insert(recent, 1, path)
    while #recent > 5 do table.remove(recent) end
end

function __impl.render(draw)
    local theme = Styles.theme()
    local n_sheets = #SemanticWorkflowProject.meta.sheets

    if n_sheets == 0 and duplicating_sheet_index == nil then
        BreitbandGraphics.draw_text2({
            rectangle = grid_rect(0, 0, 8, 16),
            text = Locales.str('SEMANTIC_WORKFLOW_PROJECT_NO_SHEETS_AVAILABLE'),
            align_x = BreitbandGraphics.alignment.center,
            align_y = BreitbandGraphics.alignment.center,
            color = theme.button.text[1],
            font_size = theme.font_size * 1.2 * Drawing.scale,
            font_name = theme.font_name,
        })
    end

    -- ── header: path + dirty indicator ──────────────────────────────────
    local top = 1
    if SemanticWorkflowProject.project_location ~= nil then
        local dirty_marker = SemanticWorkflowProject.dirty and ' [*]' or ''
        draw:small_text(
            grid_rect(0, top, 8, Gui.MEDIUM_CONTROL_HEIGHT),
            'start',
            SemanticWorkflowProject.project_location .. dirty_marker
            .. '\n' .. Locales.str('SEMANTIC_WORKFLOW_PROJECT_FILE_VERSION') .. SemanticWorkflowProject.meta.version
        )
    end

    -- ── New / Open / Save / Purge ────────────────────────────────────────
    if ugui.button({
            uid = UID.NewProject,
            rectangle = grid_rect(0, top + 1, 1.5, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PROJECT_NEW'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PROJECT_NEW_TOOL_TIP'),
        }) then
        local path = iohelper.filediag('*.swp', 1)
        if string.len(path) > 0 then
            SemanticWorkflowProject = Project.new()
            SemanticWorkflowProject.project_location = path
            SemanticWorkflowProject:save()
            track_recent(path)
            duplicating_sheet_index = nil
            selecting_sheet_base_for = nil
        end
    end

    if ugui.button({
            uid = UID.OpenProject,
            rectangle = grid_rect(1.5, top + 1, 1.5, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PROJECT_OPEN'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PROJECT_OPEN_TOOL_TIP'),
        }) then
        local path = iohelper.filediag('*.swp', 0)
        if string.len(path) > 0 then
            SemanticWorkflowProject = Project.new()
            SemanticWorkflowProject:load(path)
            track_recent(path)
            duplicating_sheet_index = nil
            selecting_sheet_base_for = nil
        end
    end

    if ugui.button({
            uid = UID.SaveProject,
            rectangle = grid_rect(3, top + 1, 1.5, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PROJECT_SAVE'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PROJECT_SAVE_TOOL_TIP'),
        }) then
        local can_save = true
        if SemanticWorkflowProject.project_location == nil then
            local path = iohelper.filediag('*.swp', 0)
            if string.len(path) == 0 then
                can_save = false
            else
                SemanticWorkflowProject.project_location = path
                track_recent(path)
            end
        end
        if can_save then
            SemanticWorkflowProject:save()
        end
    end

    if ugui.button({
            uid = UID.PurgeProject,
            rectangle = grid_rect(4.5, top + 1, 1.5, Gui.MEDIUM_CONTROL_HEIGHT),
            text = Locales.str('SEMANTIC_WORKFLOW_PROJECT_PURGE'),
            tooltip = Locales.str('SEMANTIC_WORKFLOW_PROJECT_PURGE_TOOL_TIP'),
            is_enabled = SemanticWorkflowProject.project_location ~= nil,
        }) then
        SemanticWorkflowDialog = RenderConfirmPurgeDialog
    end

    top = 3

    -- ── Recent projects (no project open yet) ────────────────────────────
    if SemanticWorkflowProject.project_location == nil then
        local recent = Settings.semantic_workflow.recent_projects
        draw:small_text(grid_rect(0, top, 8, Gui.SMALL_CONTROL_HEIGHT), 'start',
            Locales.str('SEMANTIC_WORKFLOW_PROJECT_RECENT'))
        top = top + Gui.SMALL_CONTROL_HEIGHT
        if #recent == 0 then
            draw:small_text(grid_rect(0.5, top, 7.5, Gui.SMALL_CONTROL_HEIGHT), 'start',
                Locales.str('SEMANTIC_WORKFLOW_PROJECT_NO_RECENT'))
        else
            local uid = UID.RecentProjectsBase
            for _, path in ipairs(recent) do
                if ugui.button({
                        uid = uid,
                        rectangle = grid_rect(0, top, 8, Gui.SMALL_CONTROL_HEIGHT),
                        text = path,
                    }) then
                    SemanticWorkflowProject = Project.new()
                    SemanticWorkflowProject:load(path)
                    track_recent(path)
                    duplicating_sheet_index = nil
                    selecting_sheet_base_for = nil
                end
                uid = uid + 1
                top = top + Gui.SMALL_CONTROL_HEIGHT
            end
        end
        return
    end

    -- ── DUPLICATE MODE banner (Vim-style mode line) ──────────────────────
    if duplicating_sheet_index ~= nil then
        local source_name = SemanticWorkflowProject.meta.sheets[duplicating_sheet_index].name
        BreitbandGraphics.fill_rectangle(grid_rect(0, top, 8, Gui.MEDIUM_CONTROL_HEIGHT, 0), '#B8860096')
        draw:text(grid_rect(0, top, 6, Gui.MEDIUM_CONTROL_HEIGHT), 'center',
            Locales.str('SEMANTIC_WORKFLOW_PROJECT_DUPLICATE_MODE_BANNER') .. '  ' .. source_name)
        if ugui.button({
                uid = UID.CancelDuplicate,
                rectangle = grid_rect(6, top, 2, Gui.MEDIUM_CONTROL_HEIGHT),
                text = Locales.str('SEMANTIC_WORKFLOW_PROJECT_DUPLICATE_CANCEL'),
                tooltip = Locales.str('SEMANTIC_WORKFLOW_PROJECT_DUPLICATE_CANCEL_TOOL_TIP'),
            }) then
            duplicating_sheet_index = nil
        end
        top = top + Gui.MEDIUM_CONTROL_HEIGHT
    end

    -- ── Sheet list ───────────────────────────────────────────────────────
    local available_sheets = {}
    for i = 1, n_sheets do
        available_sheets[i] = SemanticWorkflowProject.meta.sheets[i].name
    end
    available_sheets[n_sheets + 1] = Locales.str('SEMANTIC_WORKFLOW_PROJECT_ADD_SHEET')

    local uid = UID.ProjectSheetBase
    for i = 1, #available_sheets do
        local y = top + (i - 1) * Gui.MEDIUM_CONTROL_HEIGHT
        local is_real_sheet = i <= n_sheets

        -- ── DUPLICATE MODE rows ──────────────────────────────────────────
        if duplicating_sheet_index ~= nil then
            if not is_real_sheet then
                -- Append-at-end button
                if ugui.button({
                        uid = uid,
                        rectangle = grid_rect(0, y, 8, Gui.MEDIUM_CONTROL_HEIGHT),
                        text = Locales.str('SEMANTIC_WORKFLOW_PROJECT_DUPLICATE_APPEND_TOOL_TIP'),
                    }) then
                    SemanticWorkflowProject:duplicate_sheet(duplicating_sheet_index, n_sheets + 1)
                    duplicating_sheet_index = nil
                end
            else
                local is_source = (i == duplicating_sheet_index)
                if is_source then
                    BreitbandGraphics.fill_rectangle(
                        grid_rect(0, y, 8, Gui.MEDIUM_CONTROL_HEIGHT, 0), '#B8860064')
                end
                if ugui.button({
                        uid = uid,
                        rectangle = grid_rect(0, y, 8, Gui.MEDIUM_CONTROL_HEIGHT),
                        text = (is_source and '[src] ' or '\xe2\x86\x91 ') .. available_sheets[i],
                        tooltip = not is_source and Locales.str('SEMANTIC_WORKFLOW_PROJECT_DUPLICATE_INSERT_TOOL_TIP') or nil,
                        is_enabled = not is_source,
                    }) then
                    SemanticWorkflowProject:duplicate_sheet(duplicating_sheet_index, i)
                    duplicating_sheet_index = nil
                end
            end
            uid = uid + 1

        -- ── NORMAL / BASE-SHEET SELECTION MODE rows ──────────────────────
        else
            local is_checked = not SemanticWorkflowProject.disabled
                and i == SemanticWorkflowProject.meta.selection_index
            local row_tip = Locales.str(
                is_checked and 'SEMANTIC_WORKFLOW_PROJECT_DISABLE_TOOL_TIP'
                or 'SEMANTIC_WORKFLOW_PROJECT_SELECT_TOOL_TIP'
            )

            if selecting_sheet_base_for ~= nil then
                local src_sheet = SemanticWorkflowProject.all[available_sheets[selecting_sheet_base_for]]
                local function IsValidTarget()
                    if not is_real_sheet or i == selecting_sheet_base_for then return false end
                    local bs = SemanticWorkflowProject.all[available_sheets[i]]
                    while bs ~= nil do
                        if bs == src_sheet then return false end
                        bs = bs._base_sheet
                    end
                    return true
                end
                row_tip = Locales.str('SEMANTIC_WORKFLOW_PROJECT_SET_BASE_SHEET_TOOL_TIP') .. src_sheet.name
                if ugui.toggle_button({
                        uid = uid,
                        rectangle = grid_rect(0, y, 3, Gui.MEDIUM_CONTROL_HEIGHT),
                        text = available_sheets[i],
                        tooltip = is_real_sheet and row_tip or nil,
                        is_checked = false,
                        is_enabled = IsValidTarget(),
                    }) then
                    SemanticWorkflowProject.meta.sheets[selecting_sheet_base_for].base_sheet = available_sheets[i]
                    src_sheet:set_base_sheet(SemanticWorkflowProject.all[available_sheets[i]])
                    SemanticWorkflowProject:select(selecting_sheet_base_for)
                    selecting_sheet_base_for = nil
                end
            else
                if ugui.toggle_button({
                        uid = uid,
                        rectangle = grid_rect(0, y, 3, Gui.MEDIUM_CONTROL_HEIGHT),
                        text = available_sheets[i],
                        tooltip = is_real_sheet and row_tip or nil,
                        is_checked = is_checked,
                    }) then
                    if not is_real_sheet then
                        SemanticWorkflowProject:add_sheet()
                        SemanticWorkflowProject:select(#SemanticWorkflowProject.meta.sheets)
                    elseif SemanticWorkflowProject.disabled or i ~= SemanticWorkflowProject.meta.selection_index then
                        SemanticWorkflowProject:select(i)
                    end
                elseif is_checked then
                    SemanticWorkflowProject.disabled = true
                end
            end
            uid = uid + 1

            if not is_real_sheet then break end

            local sheet = SemanticWorkflowProject.all[SemanticWorkflowProject.meta.sheets[i].name]

            -- ── Per-sheet stats overlay (right side of name button) ──────────
            if sheet and sheet.sections then
                local sec_count = #sheet.sections
                local frame_count = 0
                for _, sec in ipairs(sheet.sections) do
                    frame_count = frame_count + sec.timeout
                end
                draw:small_text(
                    grid_rect(0, y, 2.9, Gui.MEDIUM_CONTROL_HEIGHT),
                    'end',
                    string.format('S:%d F:%d', sec_count, frame_count)
                )
            end

            local x = 3

            local function draw_utility_button(text, tip, enabled, width)
                width = width or 0.5
                local result = ugui.button({
                    uid = uid,
                    rectangle = grid_rect(x, y, width, Gui.MEDIUM_CONTROL_HEIGHT),
                    text = text,
                    tooltip = tip,
                    is_enabled = enabled,
                })
                uid = uid + 1
                x = x + width
                return result
            end

            local function draw_utility_toggle_button(text, tip, toggled, width)
                width = width or 0.5
                local result = ugui.toggle_button({
                    uid = uid,
                    rectangle = grid_rect(x, y, width, Gui.MEDIUM_CONTROL_HEIGHT),
                    text = text,
                    tooltip = tip,
                    is_checked = toggled,
                })
                uid = uid + 1
                x = x + width
                return result ~= toggled
            end

            if draw_utility_button('^', Locales.str('SEMANTIC_WORKFLOW_PROJECT_MOVE_SHEET_UP_TOOL_TIP'), i > 1) then
                SemanticWorkflowProject:move_sheet(i, -1)
            end
            if draw_utility_button('v', Locales.str('SEMANTIC_WORKFLOW_PROJECT_MOVE_SHEET_DOWN_TOOL_TIP'), i < n_sheets) then
                SemanticWorkflowProject:move_sheet(i, 1)
            end
            if draw_utility_button('-', Locales.str('SEMANTIC_WORKFLOW_PROJECT_DELETE_SHEET_TOOL_TIP'), true) then
                SemanticWorkflowDialog = render_confirm_deletion_prompt(i)
            end
            if draw_utility_toggle_button(
                    selecting_sheet_base_for == i and '...' or 'bs',
                    sheet._base_sheet ~= nil
                        and (Locales.str('SEMANTIC_WORKFLOW_PROJECT_BASE_SHEET_TOOL_TIP') .. sheet._base_sheet.name)
                        or Locales.str('SEMANTIC_WORKFLOW_PROJECT_NO_BASE_SHEET_TOOL_TIP'),
                    sheet._base_sheet ~= nil, 0.75) then
                selecting_sheet_base_for = selecting_sheet_base_for ~= i and i or nil
            end
            if draw_utility_toggle_button('.st', Locales.str('SEMANTIC_WORKFLOW_PROJECT_REBASE_SHEET_TOOL_TIP'), sheet._base_sheet == nil, 0.75) then
                SemanticWorkflowProject:rebase(i)
            end
            if draw_utility_button('.sws', Locales.str('SEMANTIC_WORKFLOW_PROJECT_REPLACE_INPUTS_TOOL_TIP'), true, 0.75) then
                local path = iohelper.filediag('*.sws', 0)
                if string.len(path) > 0 then sheet:load(path, false) end
            end
            if draw_utility_button('>', Locales.str('SEMANTIC_WORKFLOW_PROJECT_PLAY_WITHOUT_ST_TOOL_TIP'), true) then
                SemanticWorkflowProject:select(i, false)
            end
            if draw_utility_button('cp', Locales.str('SEMANTIC_WORKFLOW_PROJECT_DUPLICATE_TOOL_TIP'), true) then
                duplicating_sheet_index = i
                selecting_sheet_base_for = nil
            end
        end
    end
end
