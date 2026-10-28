local mod = get_mod("interrogator_randall")
return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = true,
    options = {
        widgets = {
            -- v0.21.7: Group each category's LIVE and END-OF-MISSION
            -- checkboxes together. These are purely visual groups; the
            -- original saved setting IDs, defaults, and logic are unchanged.
            { setting_id = "group_ammo", type = "group", sub_widgets = {
                { setting_id = "report_ammo", type = "checkbox", default_value = true,
                  tooltip = "report_ammo_tooltip" },
                { setting_id = "report_end_ammo_summary", type = "checkbox", default_value = true,
                  tooltip = "report_end_ammo_summary_tooltip" },
                { setting_id = "report_end_ammo_team_total", type = "checkbox", default_value = true,
                  tooltip = "report_end_ammo_team_total_tooltip" },
            } },
            { setting_id = "group_grenades", type = "group", sub_widgets = {
                { setting_id = "report_grenades", type = "checkbox", default_value = true,
                  tooltip = "report_grenades_tooltip" },
                { setting_id = "report_end_grenade_summary", type = "checkbox", default_value = true,
                  tooltip = "report_end_grenade_summary_tooltip" },
                { setting_id = "report_end_grenade_team_total", type = "checkbox", default_value = true,
                  tooltip = "report_end_grenade_team_total_tooltip" },
            } },
            { setting_id = "group_barrels", type = "group", sub_widgets = {
                { setting_id = "report_barrels", type = "checkbox", default_value = true,
                  tooltip = "report_barrels_tooltip" },
                { setting_id = "report_end_barrel_summary", type = "checkbox", default_value = true,
                  tooltip = "report_end_barrel_summary_tooltip" },
                { setting_id = "report_end_barrel_team_total", type = "checkbox", default_value = true,
                  tooltip = "report_end_barrel_team_total_tooltip" },
            } },
            { setting_id = "group_poxbursters", type = "group", sub_widgets = {
                { setting_id = "report_poxbursters", type = "checkbox", default_value = true,
                  tooltip = "report_poxbursters_tooltip" },
                { setting_id = "report_end_poxburster_summary", type = "checkbox", default_value = true,
                  tooltip = "report_end_poxburster_summary_tooltip" },
                { setting_id = "report_end_poxburster_team_total", type = "checkbox", default_value = true,
                  tooltip = "report_end_poxburster_team_total_tooltip" },
            } },
            { setting_id = "group_medicae", type = "group", sub_widgets = {
                { setting_id = "report_medicae", type = "checkbox", default_value = true,
                  tooltip = "report_medicae_tooltip" },
                { setting_id = "report_end_medicae_summary", type = "checkbox", default_value = true,
                  tooltip = "report_end_medicae_summary_tooltip" },
                { setting_id = "report_end_medicae_team_total", type = "checkbox", default_value = true,
                  tooltip = "report_end_medicae_team_total_tooltip" },
            } },
            { setting_id = "group_med_stimm", type = "group", sub_widgets = {
                { setting_id = "report_med_stimm", type = "checkbox", default_value = true,
                  tooltip = "report_med_stimm_tooltip" },
                { setting_id = "report_end_med_stimm_summary", type = "checkbox", default_value = true,
                  tooltip = "report_end_med_stimm_summary_tooltip" },
                { setting_id = "report_end_med_stimm_team_total", type = "checkbox", default_value = true,
                  tooltip = "report_end_med_stimm_team_total_tooltip" },
            } },
            { setting_id = "group_daemonhost", type = "group", sub_widgets = {
                { setting_id = "report_daemonhost", type = "checkbox", default_value = true,
                  tooltip = "report_daemonhost_tooltip" },
            } },

            -- v0.21.8: An independent collapsible slider category gives
            -- Daemonhosts a clear visual boundary before the waste settings.
            -- Slider IDs, ranges, defaults, and live-only behavior are unchanged.
            { setting_id = "group_waste_sliders", type = "group", sub_widgets = {
                { setting_id = "minimum_waste_to_report", type = "numeric",
                  tooltip = "minimum_waste_to_report_tooltip",
                  default_value = 50, range = {0, 100}, step_size_value = 1,
                  decimals_number = 0 },
                { setting_id = "minimum_grenade_waste_to_report", type = "numeric",
                  tooltip = "minimum_grenade_waste_to_report_tooltip",
                  default_value = 50, range = {0, 100}, step_size_value = 1,
                  decimals_number = 0 },
                { setting_id = "minimum_medicae_waste_to_report", type = "numeric",
                  tooltip = "minimum_medicae_waste_to_report_tooltip",
                  default_value = 50, range = {0, 100}, step_size_value = 1,
                  decimals_number = 0 },
                { setting_id = "minimum_med_stimm_waste_to_report", type = "numeric",
                  tooltip = "minimum_med_stimm_waste_to_report_tooltip",
                  default_value = 50, range = {0, 100}, step_size_value = 1,
                  decimals_number = 0 },
            } },

            -- Advanced options; all existing behavior preserved.
            { setting_id = "diagnostic_logging", type = "checkbox", default_value = false,
              tooltip = "diagnostic_logging_tooltip" },
            { setting_id = "report_toughness", type = "checkbox", default_value = true,
              tooltip = "report_toughness_tooltip" },
            { setting_id = "report_harmless_explosions", type = "checkbox", default_value = false,
              tooltip = "report_harmless_explosions_tooltip" },
        },
    },
}
