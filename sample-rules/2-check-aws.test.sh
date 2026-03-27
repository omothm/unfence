run_test "aws describe-*" \
  'aws --profile esw --region eu-west-1 elbv2 describe-load-balancers --json' "allow"
run_test "aws list-*" \
  'aws lambda list-functions --region us-east-1' "allow"
run_test "aws get-*" \
  'aws sts get-caller-identity' "allow"
run_test "aws filter-log-events" \
  'aws logs filter-log-events --profile esw-prod --region eu-west-1 --log-group-name "/aws/ecs/test" --limit 20 --output json' "allow"
run_test "aws s3 cp → defer (mutating)" \
  'aws s3 cp file.txt s3://bucket/' "defer"
run_test "aws s3 rm → defer" \
  'aws s3 rm s3://bucket/file.txt' "defer"
run_test "aws ec2 terminate → defer" \
  'aws ec2 terminate-instances --instance-ids i-123' "defer"
