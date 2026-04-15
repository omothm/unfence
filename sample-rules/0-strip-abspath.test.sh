# Tests for 0-strip-abspath.sh
# Verifies that absolute system-path prefixes are stripped and the pipeline
# re-evaluates with the bare command name, producing the same verdict as
# the bare form would.

# /usr/bin/*
run_test "/usr/bin/jq → allow"            '/usr/bin/jq -r .foo'         "allow"
run_test "/usr/bin/cat → allow"           '/usr/bin/cat file.txt'        "allow"
run_test "/usr/bin/git log → allow"       '/usr/bin/git log --oneline'   "allow"
run_test "/usr/bin/git push → ask"        '/usr/bin/git push'            "ask"

# /usr/local/bin/*
run_test "/usr/local/bin/jq → allow"     '/usr/local/bin/jq .'          "allow"

# /bin/*
run_test "/bin/cat → allow"              '/bin/cat file.txt'             "allow"

# /opt/homebrew/bin/* (macOS Homebrew)
run_test "/opt/homebrew/bin/jq → allow"  '/opt/homebrew/bin/jq .'       "allow"

# No args
run_test "/usr/bin/jq no args → allow"   '/usr/bin/jq'                  "allow"

# Custom / unknown path — rule should defer (not a known system directory)
run_test "custom /home path → defer"     '/home/user/bin/mytool arg'    "defer"
run_test "/tmp script → defer"           '/tmp/script.sh arg'           "defer"

# Relative path — rule does not apply (not absolute)
run_test "relative ./script → defer"     './my-script.sh'               "defer"

# Bare command — rule does not apply, downstream handles it normally
run_test "bare jq → allow (no strip)"    'jq -r .foo'                   "allow"
