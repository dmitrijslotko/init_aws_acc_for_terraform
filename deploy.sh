#!/bin/bash
# Script to create an S3 bucket and DynamoDB table for Terraform state storage
# Configuration is passed directly as command-line arguments

# Function to check if AWS CLI is installed and configured
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        echo "Error: AWS CLI is not installed. Please install it and configure it with your AWS credentials."
        echo "See: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        exit 1
    fi

    if ! aws sts get-caller-identity &> /dev/null; then
        echo "Error: AWS CLI is not configured. Please run 'aws configure' to set up your credentials."
        echo "See: https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html"
        exit 1
    fi
}

# Function to create the S3 bucket
create_s3_bucket() {
    local bucket_name="$1"
    local aws_region="$2"
    local aws_account_id="$3" # Added AWS_ACCOUNT_ID

    echo "Creating S3 bucket: $bucket_name in region $aws_region for account $aws_account_id..."
    if aws s3api create-bucket \
        --bucket "$bucket_name" \
        --region "$aws_region" \
        --create-bucket-configuration "LocationConstraint=$aws_region" &> /dev/null
    then
        echo "S3 bucket created successfully."
        # Enable versioning
        echo "Enabling versioning for S3 bucket: $bucket_name..."
        if aws s3api put-bucket-versioning --bucket "$bucket_name" --versioning-configuration Status=Enabled --region "$aws_region" &> /dev/null; then
            echo "Versioning enabled for S3 bucket."
        else
            echo "Warning: Failed to enable versioning for the S3 bucket. This is recommended for production use."
        fi
        return 0
    else
        echo "Error creating S3 bucket. It may already exist, or you may not have permissions."
        echo "Checking if the bucket exists..."
        if aws s3 ls "s3://$bucket_name" &> /dev/null; then
           echo "The bucket '$bucket_name' already exists. Please choose a unique name, or use an existing bucket."
           return 1
        else
           echo "Error: Failed to create S3 bucket and it does not appear to exist. Please check your AWS credentials and permissions."
           return 1
        fi
    fi
}

# Function to create the DynamoDB table
create_dynamodb_table() {
    local table_name="$1"
    local aws_region="$2"
    local aws_account_id="$3" # Added AWS_ACCOUNT_ID

    echo "Creating DynamoDB table: $table_name in region $aws_region for account $aws_account_id..."
    if aws dynamodb create-table \
        --table-name "$table_name" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$aws_region" &> /dev/null
    then
        echo "DynamoDB table created successfully."
        # Wait for table to be ready
        echo "Waiting for DynamoDB table to become active..."
        aws dynamodb wait table-exists --table-name "$table_name" --region "$aws_region"
        echo "DynamoDB table is now active."
        return 0
    else
        echo "Error creating DynamoDB table. It may already exist, or you may not have permissions."
        echo "Checking if table exists..."
        if aws dynamodb describe-table --table-name "$table_name" --region "$aws_region" &> /dev/null; then
            echo "The table '$table_name' already exists. Please choose a unique name, or use an existing table."
            return 1
        else
            echo "Error: Failed to create DynamoDB table and it does not appear to exist. Please check your AWS credentials and permissions."
            return 1
        fi
    fi
}

# --- Main Script ---

# Check for the correct number of arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <aws_region> <environment> <aws_account_id>"
    exit 1
fi

AWS_REGION="$1"
ENVIRONMENT="$2"
AWS_ACCOUNT_ID="$3" # Capture the new argument

S3_BUCKET_NAME="terraform-state-${AWS_ACCOUNT_ID}-${ENVIRONMENT}"
DYNAMODB_TABLE_NAME="terraform-locks-${AWS_ACCOUNT_ID}-${ENVIRONMENT}"

# Perform initial checks
check_aws_cli

# Create the S3 bucket
create_s3_bucket "$S3_BUCKET_NAME" "$AWS_REGION" "$AWS_ACCOUNT_ID"
S3_CREATE_STATUS=$?

# Create the DynamoDB table only if S3 bucket creation was successful
if [ "$S3_CREATE_STATUS" -eq 0 ]; then
    create_dynamodb_table "$DYNAMODB_TABLE_NAME" "$AWS_REGION" "$AWS_ACCOUNT_ID"
    DYNAMODB_CREATE_STATUS=$?
fi

# Output Terraform backend configuration if both operations were successful
if [ "$S3_CREATE_STATUS" -eq 0 ] && [ "$DYNAMODB_CREATE_STATUS" -eq 0 ]; then
  echo "
  Terraform backend configuration:

  terraform {
    backend \"s3\" {
      bucket         = \"$S3_BUCKET_NAME\"
      key            = \"terraform/state\"  # Change this as needed for your project structure
      region         = \"$AWS_REGION\"
      dynamodb_table = \"$DYNAMODB_TABLE_NAME\"
      # No need to specify AWS_ACCOUNT_ID in the backend configuration
    }
  }

  Add this configuration to your Terraform project's main.tf file (or a separate backend.tf file).
  "
fi

exit 0