# The fixture configuration of the G-10 probe: release configurations that switch feature
# flags on. The probe has to report them, because a feature flag is off by default. One is
# written in the directive form (`config :app, :key, value`) and one in the keyword form
# (`config :app, key: value`): both switch a flag on.
config :letflow, :g10_release_flag, true
config :letflow, g10_keyword_flag: true
