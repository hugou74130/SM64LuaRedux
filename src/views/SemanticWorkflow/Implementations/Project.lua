--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

---@type Project
---@diagnostic disable-next-line: assign-type-mismatch
local __impl = __impl

---@type Sheet
local Sheet = dofile(views_path .. 'SemanticWorkflow/Definitions/Sheet.lua')

local function new_sheet_meta(name)
    return {
        name = name,
        base_sheet = nil,
    }
end

local function auto_save(project)
    if project.project_location ~= nil then
        project:save()
    end
end

function __impl.new()
    return {
        meta = {
            version = SEMANTIC_WORKFLOW_FILE_VERSION,
            created_sheet_count = 0,
            selection_index = 0,
            sheets = {},
        },
        all = {},
        project_location = nil,
        disabled = false,
        dirty = false,

        current = __impl.current,
        asserted_current = __impl.asserted_current,
        set_current_name = __impl.set_current_name,
        project_folder = __impl.project_folder,
        load = __impl.load,
        save = __impl.save,
        add_sheet = __impl.add_sheet,
        remove_sheet = __impl.remove_sheet,
        move_sheet = __impl.move_sheet,
        duplicate_sheet = __impl.duplicate_sheet,
        select = __impl.select,
        rebase = __impl.rebase,
    }
end

function __impl:asserted_current()
    local result = self:current()
    if result == nil then
        error('Expected the current sheet to not be nil.', 2)
    end
    return result
end

function __impl:current()
    local sheet_meta = self.meta.sheets[self.meta.selection_index]
    return sheet_meta ~= nil and self.all[sheet_meta.name] or nil
end

function __impl:add_sheet()
    self.meta.created_sheet_count = self.meta.created_sheet_count + 1
    local new_sheet = Sheet.new('Sheet ' .. self.meta.created_sheet_count, true)
    self.all[new_sheet.name] = new_sheet
    self.meta.sheets[#self.meta.sheets + 1] = new_sheet_meta(new_sheet.name)
    self.dirty = true
    auto_save(self)
end

function __impl:remove_sheet(index)
    self.all[table.remove(self.meta.sheets, index).name] = nil
    self:select(#self.meta.sheets > 0 and (index % #self.meta.sheets) or 0)
    self.dirty = true
    auto_save(self)
end

function __impl:move_sheet(index, sign)
    local tmp = self.meta.sheets[index]
    self.meta.sheets[index] = self.meta.sheets[index + sign]
    self.meta.sheets[index + sign] = tmp
    self.dirty = true
    auto_save(self)
end

function __impl:duplicate_sheet(from_index, to_index)
    local source_meta = self.meta.sheets[from_index]
    local source_sheet = self.all[source_meta.name]
    local new_name = source_sheet.name .. ' (copy)'
    local counter = 2
    while self.all[new_name] ~= nil do
        new_name = source_sheet.name .. ' (copy ' .. counter .. ')'
        counter = counter + 1
    end
    self.meta.created_sheet_count = self.meta.created_sheet_count + 1
    local cloned = source_sheet:clone(new_name)
    self.all[new_name] = cloned
    local cloned_meta = new_sheet_meta(new_name)
    if source_meta.base_sheet ~= nil then
        cloned_meta.base_sheet = source_meta.base_sheet
        cloned:set_base_sheet(self.all[source_meta.base_sheet])
    end
    table.insert(self.meta.sheets, to_index, cloned_meta)
    self.dirty = true
    auto_save(self)
end

function __impl:set_current_name(name)
    local current_sheet_meta = self.meta.sheets[self.meta.selection_index]

    -- short circuit if there is nothing to do
    if name == current_sheet_meta.name then return end

    local sheet = self.all[current_sheet_meta.name]
    self.all[current_sheet_meta.name] = nil
    self.all[name] = sheet
    current_sheet_meta.name = name
    self.dirty = true
    auto_save(self)
end

function __impl:select(index, load_state)
    self.disabled = false
    local previous = self:current()
    if previous ~= nil then previous.busy = false end
    self.meta.selection_index = index
    local current = self:current()
    if current ~= nil then
        current:run_to_preview(load_state)
    end
end

function __impl:rebase(index)
    self.meta.selection_index = index
    self.all[self.meta.sheets[index].name]:rebase()
end

function __impl:project_folder()
    return self.project_location:match('(.*[/\\])')
end

function __impl:load(file)
    self.project_location = file
    CloneInto(self.meta, json.decode(ReadAll(file)))
    self.all = {}
    self.dirty = false
    local project_folder = self:project_folder()
    for _, sheet_meta in ipairs(self.meta.sheets) do
        self.all[sheet_meta.name] = Sheet.new(sheet_meta.name, false)
    end

    for _, sheet_meta in ipairs(self.meta.sheets) do
        local new_sheet = self.all[sheet_meta.name]
        local has_state = sheet_meta.base_sheet == nil
        new_sheet:load(project_folder .. sheet_meta.name .. '.sws', has_state)
        if not has_state then
            self.all[sheet_meta.name]:set_base_sheet(self.all[sheet_meta.base_sheet])
        end
    end
end

function __impl:save()
    self.meta.version = SEMANTIC_WORKFLOW_FILE_VERSION
    local encoded = json.encode(self.meta)
    if encoded == nil then
        print("[SemanticWorkflow] warning: failed to encode project metadata to JSON; writing empty string")
        encoded = ''
    end
    WriteAll(SemanticWorkflowProject.project_location, encoded)

    local project_folder = SemanticWorkflowProject:project_folder()
    for _, sheet_meta in ipairs(SemanticWorkflowProject.meta.sheets) do
        SemanticWorkflowProject.all[sheet_meta.name]:save(project_folder .. sheet_meta.name .. '.sws')
    end
    self.dirty = false
end
