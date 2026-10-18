-- Tools/Reference/node-info.lua: each classic node's required skill and the item
-- it gives, keyed by GatherMate2's node ID (Tools/Reference/gathermate2.lua's
-- `node`). An input to Tools/export_nodes.lua, which joins it to every
-- language's names as NodeRadar.NODE_INFO (#26); never loaded by the addon.
--
-- The Classic (1.12) values, checked against Lueur 1.2.0's table. Forever
-- keeps them: Mageroyal refused at Herbalism 25, "Requires Herbalism 50"
-- (docs/FOREVER-PROBE.md, 70450). The ooze-covered veins share their base
-- vein's. No skill where unsure: Hakkari Thorium Vein (216), Bloodvine (430)
-- and the AQ obsidian chunks (225, 226) alert whatever the skill.

NodeRadarNodeInfo = {
    -- Mining
    [201] = { skill = 1, item = 2770 },     -- Copper Vein
    [202] = { skill = 65, item = 2771 },    -- Tin Vein
    [203] = { skill = 125, item = 2772 },   -- Iron Deposit
    [204] = { skill = 75, item = 2775 },    -- Silver Vein
    [205] = { skill = 155, item = 2776 },   -- Gold Vein
    [206] = { skill = 175, item = 3858 },   -- Mithril Deposit
    [207] = { skill = 175, item = 3858 },   -- Ooze Covered Mithril Deposit
    [208] = { skill = 230, item = 7911 },   -- Truesilver Deposit
    [209] = { skill = 75, item = 2775 },    -- Ooze Covered Silver Vein
    [210] = { skill = 155, item = 2776 },   -- Ooze Covered Gold Vein
    [211] = { skill = 230, item = 7911 },   -- Ooze Covered Truesilver Deposit
    [212] = { skill = 275, item = 10620 },  -- Ooze Covered Rich Thorium Vein
    [213] = { skill = 245, item = 10620 },  -- Ooze Covered Thorium Vein
    [214] = { skill = 245, item = 10620 },  -- Small Thorium Vein
    [215] = { skill = 275, item = 10620 },  -- Rich Thorium Vein
    [216] = { item = 10620 },               -- Hakkari Thorium Vein
    [217] = { skill = 230, item = 11370 },  -- Dark Iron Deposit
    [218] = { skill = 75, item = 4278 },    -- Lesser Bloodstone Deposit
    [219] = { skill = 65, item = 3340 },    -- Incendicite Mineral Vein
    [220] = { skill = 150, item = 5833 },   -- Indurium Mineral Vein
    [225] = {},                             -- Large Obsidian Chunk
    [226] = {},                             -- Small Obsidian Chunk
    -- Herbalism
    [401] = { skill = 1, item = 2447 },     -- Peacebloom
    [402] = { skill = 1, item = 765 },      -- Silverleaf
    [403] = { skill = 15, item = 2449 },    -- Earthroot
    [404] = { skill = 50, item = 785 },     -- Mageroyal
    [405] = { skill = 70, item = 2450 },    -- Briarthorn
    [407] = { skill = 85, item = 3820 },    -- Stranglekelp
    [408] = { skill = 100, item = 2453 },   -- Bruiseweed
    [409] = { skill = 115, item = 3355 },   -- Wild Steelbloom
    [410] = { skill = 120, item = 3369 },   -- Grave Moss
    [411] = { skill = 125, item = 3356 },   -- Kingsblood
    [412] = { skill = 150, item = 3357 },   -- Liferoot
    [413] = { skill = 160, item = 3818 },   -- Fadeleaf
    [414] = { skill = 170, item = 3821 },   -- Goldthorn
    [415] = { skill = 185, item = 3358 },   -- Khadgar's Whisker
    [416] = { skill = 195, item = 3819 },   -- Wintersbite
    [417] = { skill = 205, item = 4625 },   -- Firebloom
    [418] = { skill = 210, item = 8831 },   -- Purple Lotus
    [420] = { skill = 220, item = 8836 },   -- Arthas' Tears
    [421] = { skill = 230, item = 8838 },   -- Sungrass
    [422] = { skill = 235, item = 8839 },   -- Blindweed
    [423] = { skill = 245, item = 8845 },   -- Ghost Mushroom
    [424] = { skill = 250, item = 8846 },   -- Gromsblood
    [425] = { skill = 260, item = 13464 },  -- Golden Sansam
    [426] = { skill = 270, item = 13463 },  -- Dreamfoil
    [427] = { skill = 280, item = 13465 },  -- Mountain Silversage
    [428] = { skill = 285, item = 13466 },  -- Plaguebloom
    [429] = { skill = 290, item = 13467 },  -- Icecap
    [430] = {},                             -- Bloodvine
    [431] = { skill = 300, item = 13468 },  -- Black Lotus
}
