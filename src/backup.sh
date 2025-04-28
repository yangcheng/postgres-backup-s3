#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

echo "Creating backup of $POSTGRES_DATABASE database..."
pg_dump --format=custom \
        -h $POSTGRES_HOST \
        -p $POSTGRES_PORT \
        -U $POSTGRES_USER \
        -d $POSTGRES_DATABASE \
        $PGDUMP_EXTRA_OPTS \
        > /tmp/db.dump # Correctly writing dump to /tmp

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"

if [ -n "$PASSPHRASE" ]; then
  echo "Encrypting backup..."
  rm -f /tmp/db.dump.gpg
  gpg --symmetric --batch --passphrase "$PASSPHRASE" --output /tmp/db.dump.gpg /tmp/db.dump
  rm /tmp/db.dump
  local_file="/tmp/db.dump.gpg"
  s3_uri="${s3_uri_base}.gpg"
else
  local_file="/tmp/db.dump"
  s3_uri="$s3_uri_base"
fi

echo "Uploading backup to $S3_BUCKET..."
aws $aws_args s3 cp "$local_file" "$s3_uri"
upload_exit_code=$? # Capture exit code of aws s3 cp
if [ $upload_exit_code -ne 0 ]; then
    echo "ERROR: S3 upload failed with exit code: $upload_exit_code"
    exit $upload_exit_code # Exit immediately if upload fails
fi
rm "$local_file"

echo "Backup complete." # This should print if upload and local cleanup succeed

# --- Cleanup block ---
if [ -n "$BACKUP_KEEP_DAYS" ]; then
  echo "Removing old backups from $S3_BUCKET..."

  # --- MODIFIED DATE CALCULATION ---
  # Try the simpler relative date format
  # This line replaces the complex one around original line 90
  date_from_remove=$(date -d "${BACKUP_KEEP_DAYS} days ago" +%Y-%m-%d)
  # -------------------------------

  # Check if date command succeeded
  if [ $? -ne 0 ]; then
      echo "ERROR: date command failed after modification. Check date command syntax or BACKUP_KEEP_DAYS value."
      exit 1
  fi
  echo "Calculated removal date: $date_from_remove" # Add logging

  backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

  # Execute the cleanup pipeline and capture its exit code
  set +e # Temporarily disable set -e for pipeline status check

  echo "Listing objects in s3://${S3_BUCKET}/${S3_PREFIX} older than ${date_from_remove}..."
  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}" \
    --query "${backups_query}" \
    --output text \
    | xargs -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'

  cleanup_pipeline_exit_code=${PIPESTATUS[1]} # Capture exit code of xargs
  set -e # Re-enable set -e

  echo "Cleanup pipeline finished. aws s3api list-objects exit: ${PIPESTATUS[0]}, xargs exit: ${PIPESTATUS[1]}, overall pipe status: $?"
  echo "Cleanup pipeline exit code captured: $cleanup_pipeline_exit_code"

  if [ "$cleanup_pipeline_exit_code" -ne 0 ]; then
      echo "WARNING: Cleanup pipeline returned a non-zero exit code ($cleanup_pipeline_exit_code). This may indicate some files failed to delete."
      # The script will still exit due to set -e unless you add Option B logic here
  fi

  echo "Removal complete." # This should print if the cleanup block finishes without a hard error
fi

# If the script reaches here, it means everything before it succeeded
echo "backup.sh script finished successfully."
exit 0 # Explicitly exit with status 0 for success