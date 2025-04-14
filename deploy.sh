#!/bin/bash
# Script to create an S3 bucket and DynamoDB table for Terraform state storage
# Configuration is now read from a config file, with optional command-line argument
# Script will exit if config file is not provided or is incomplete

# Default configuration file path
CONFIG_FILE="config.conf"

# Function to load configuration from the config file
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # Read the config file line by line
        while read -r line; do
            if [[ "$line" == *=* ]]; then
                IFS='=' read -r key value <<< "$line"
                # Remove leading/trailing whitespace
                key=$(echo "$key" | tr -d ' ')
                value=$(echo "$value" | tr -d " '") # Remove both spaces and quotes

                case "$key" in
                    AWS_REGION)
                        AWS_REGION="$value"
                        ;;
                    ENVIRONMENT)
                        ENVIRONMENT="$value"
                        ;;
                    POSTFIX)
                        POSTFIX="$value"
                        ;;
                    *)
                        # Ignore unknown parameters
                        ;;
                esac
            fi
        done < "$CONFIG_FILE"
    else
        echo "Error: Configuration file not found. Please provide a configuration file."
        exit 1
    fi

    # Check for mandatory parameters
    if [ -z "$AWS_REGION" ] || [ -z "$ENVIRONMENT" ] || [ -z "$POSTFIX" ]; then
        echo "Error: Missing mandatory parameters in configuration file.  Please ensure AWS_REGION, ENVIRONMENT, and POSTFIX are defined."
        exit 1
    fi
}

# Check for command-line argument for config file path
if [ $# -eq 1 ]; then
    CONFIG_FILE="$1"
    # No need to echo this
elif [ $# -gt 1 ]; then
    echo "Usage: $0 [config_file_path]"
    exit 1
fi

# Load the configuration
load_config

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null
then
    echo "AWS CLI is not installed. Please install it and configure it with your AWS credentials."
    echo "See: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
    exit 1
fi

# Check if AWS CLI is configured
if ! aws sts get-caller-identity &> /dev/null
then
    echo "AWS CLI is not configured.  Please run 'aws configure' to set up your credentials."
    echo "See: https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html"
    exit 1
fi

# S3 Bucket Name
S3_BUCKET_NAME="terraform-state-${POSTFIX}"
# DynamoDB Table Name
DYNAMODB_TABLE_NAME="terraform-locks-${POSTFIX}"

# Function to create the S3 bucket
create_s3_bucket() {
    echo "Creating S3 bucket: $S3_BUCKET_NAME in region $AWS_REGION..."
    if aws s3api create-bucket \
        --bucket "$S3_BUCKET_NAME" \
        --region "$AWS_REGION" \
        --create-bucket-configuration "LocationConstraint=$AWS_REGION" &> /dev/null
    then
        echo "S3 bucket created successfully."
    else
        echo "Error creating S3 bucket.  It may already exist, or you may not have permissions."
        echo "Checking if the bucket exists..."
        if aws s3 ls "s3://$S3_BUCKET_NAME" &> /dev/null; then
           echo "The bucket '$S3_BUCKET_NAME' already exists.  Please choose a unique name, or use an existing bucket."
           return 1 # Return 1 to indicate failure
        else
           echo "Error: Failed to create S3 bucket and it does not appear to exist.  Please check your AWS credentials and permissions."
           return 1
        fi
    fi

    # Enable versioning on the S3 bucket (recommended for Terraform state)
    echo "Enabling versioning for S3 bucket: $S3_BUCKET_NAME..."
    if aws s3api put-bucket-versioning --bucket "$S3_BUCKET_NAME" --versioning-configuration Status=Enabled --region "$AWS_REGION" &> /dev/null
    then
        echo "Versioning enabled for S3 bucket."
    else
        echo "Warning: Failed to enable versioning for the S3 bucket.  This is recommended for production use."
    fi
}

# Function to create the DynamoDB table
create_dynamodb_table() {
    echo "Creating DynamoDB table: $DYNAMODB_TABLE_NAME in region $AWS_REGION..."
    if aws dynamodb create-table \
        --table-name "$DYNAMODB_TABLE_NAME" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$AWS_REGION" &> /dev/null
    then
        echo "DynamoDB table created successfully."
    else
        echo "Error creating DynamoDB table. It may already exist, or you may not have permissions."
        echo "Checking if table exists..."
        if aws dynamodb describe-table --table-name "$DYNAMODB_TABLE_NAME" --region "$AWS_REGION" &> /dev/null; then
            echo "The table '$DYNAMODB_TABLE_NAME' already exists.  Please choose a unique name, or use an existing table."
            return 1 # Return 1 to indicate failure
        else
            echo "Error: Failed to create DynamoDB table and it does not appear to exist.  Please check your AWS credentials and permissions."
            return 1
        fi
    fi

    # Wait for the DynamoDB table to be ready
    echo "Waiting for DynamoDB table to become active..."
    aws dynamodb wait table-exists --table-name "$DYNAMODB_TABLE_NAME" --region "$AWS_REGION"
    echo "DynamoDB table is now active."
}

# Main script logic
create_s3_bucket
if [ $? -eq 0 ]; then # Only create DynamoDB table if S3 bucket creation was successful
   create_dynamodb_table
fi

if [ $? -eq 0 ]; then
  echo "
  Terraform backend configuration:

  terraform {
    backend \"s3\" {
      bucket         = \"$S3_BUCKET_NAME\"
      key            = \"terraform/state\"  #  Change this as needed for your project structure
      region         = \"$AWS_REGION\"
      dynamodb_table = \"$DYNAMODB_TABLE_NAME\"
    }
  }

  Add this configuration to your Terraform project's main.tf file (or a separate backend.tf file).
  Don't forget to replace the bucket name and region if you changed them in the script.
  "
fi
