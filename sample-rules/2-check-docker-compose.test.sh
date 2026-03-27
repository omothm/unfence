run_test "docker-compose up" \
  'docker-compose -f /path/to/docker-compose.yml up -d postgres redis 2>&1' "allow"
run_test "docker-compose ps" \
  'docker-compose ps' "allow"
run_test "docker-compose down" \
  'docker-compose down' "allow"
