--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

---@class InputListGui : Gui The control that displays and selects the selected sheet's sections.
---@field special_select_handler fun(selection_input) | nil A callback that overrides the behavior when an input row would normally be selected.
local cls_input_list_gui = {
    special_select_handler = nil,
}

__impl = cls_input_list_gui
dofile(views_path .. 'SemanticWorkflow/Implementations/InputListGui.lua')
__impl = nil

return cls_input_list_gui
