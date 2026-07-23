--
-- Copyright (c) 2025, Mupen64 maintainers.
--
-- SPDX-License-Identifier: GPL-2.0-or-later
--

--
-- Bruteforce input processor.
--
-- Placed LAST in the processor pipeline so it sees the final per-frame input (after the semantic
-- workflow and movement processors). While a search is running it overrides the input with the
-- current candidate; otherwise it is a pass-through. All logic lives in BruteforceDriver
-- (views/Bruteforce.lua), which is loaded before the processors in SM64Lua.lua.
--

return {
    process = function(input)
        return BruteforceDriver.process(input)
    end,
}
