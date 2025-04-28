#! /bin/sh

set -eu

# TEMPORARILY COMMENT OUT THE AWS CONFIGURE LINE FOR TESTING
# if [ "$S3_S3V4" = "yes" ]; then
#   echo "Setting S3 signature version to s3v4..."
#   aws configure set default.s3.signature_version s3v4
#   # Add a check here just in case 'aws configure' itself fails
#   if [ $? -ne 0 ]; then
#       echo "ERROR: aws configure failed."
#       exit 1
#   fi
# fi
# echo "aws configure block skipped for testing." # Add log to confirm it's skipped

if [ -z "$SCHEDULE" ]; then
  echo "SCHEDULE environment variable is not set. Running backup.sh in single execution mode."
  # Explicitly run backup.sh and capture its exit code
  sh backup.sh
  backup_exit_code=$? # Capture the exit code of sh backup.sh

  echo "backup.sh finished execution with exit code: $backup_exit_code"

  # Explicitly exit run.sh with the captured exit code
  exit $backup_exit_code
else
  echo "SCHEDULE environment variable IS set ('$SCHEDULE'). Running backup.sh in scheduled daemon mode with go-cron."
  exec go-cron "$SCHEDULE" /bin/sh backup.sh
fi