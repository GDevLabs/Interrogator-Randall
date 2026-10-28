return {
    run = function()
        fassert(rawget(_G, "new_mod"), "interrogator_randall requires the Darktide Mod Framework.")
        new_mod("interrogator_randall", {
            mod_script = "interrogator_randall/scripts/mods/interrogator_randall/interrogator_randall",
            mod_data = "interrogator_randall/scripts/mods/interrogator_randall/interrogator_randall_data",
            mod_localization = "interrogator_randall/scripts/mods/interrogator_randall/interrogator_randall_localization",
        })
    end,
    packages = {},
}
