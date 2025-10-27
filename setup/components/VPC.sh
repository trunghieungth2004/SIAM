#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| VPC Infrastructure Component       |--/ /-|#
#|-/ /--| Creates VPC, Subnets, Gateways     |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

setup_vpc() {
    print_log -b "[network] " "Setting up VPC Infrastructure..."
    validate_inputs
    setup_aws_environment

    # --- Building the Secure Network ---
    print_log -b "[network] " "Checking for existing VPC..."
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=${PROJECT_NAME}" --query "Vpcs[0].VpcId" --output text)
    if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
        print_log -c "[create] " "Creating VPC..."
        VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text)
        aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value="vpc-${PROJECT_NAME}" Key=Project,Value=$PROJECT_NAME
        
        print_log -c "[config] " "Enabling DNS support and DNS hostnames for VPC..."
        aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
        aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
    else
        print_log -y "[skip] " "VPC for project '${PROJECT_NAME}' already exists: ${VPC_ID}"
        
        print_log -c "[config] " "Ensuring DNS support and DNS hostnames are enabled..."
        aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
        aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
    fi

    # Get first available AZ
    AVAILABILITY_ZONE=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].ZoneName" --output text)
    
    PUBLIC_SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=public-subnet-${PROJECT_NAME}" --query "Subnets[0].SubnetId" --output text)
    if [ "$PUBLIC_SUBNET_ID" == "None" ] || [ -z "$PUBLIC_SUBNET_ID" ]; then
        print_log -c "[create] " "Creating Public Subnet in AZ: ${AVAILABILITY_ZONE}..."
        PUBLIC_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.0.0/24 --availability-zone $AVAILABILITY_ZONE --query Subnet.SubnetId --output text)
        aws ec2 create-tags --resources $PUBLIC_SUBNET_ID --tags Key=Name,Value="public-subnet-${PROJECT_NAME}"
        aws ec2 modify-subnet-attribute --subnet-id $PUBLIC_SUBNET_ID --map-public-ip-on-launch
    else
        print_log -y "[skip] " "Public Subnet already exists: ${PUBLIC_SUBNET_ID}"
    fi

    PRIVATE_SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=private-subnet-${PROJECT_NAME}" --query "Subnets[0].SubnetId" --output text)
    if [ "$PRIVATE_SUBNET_ID" == "None" ] || [ -z "$PRIVATE_SUBNET_ID" ]; then
        print_log -c "[create] " "Creating Private Subnet in AZ: ${AVAILABILITY_ZONE}..."
        PRIVATE_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone $AVAILABILITY_ZONE --query Subnet.SubnetId --output text)
        aws ec2 create-tags --resources $PRIVATE_SUBNET_ID --tags Key=Name,Value="private-subnet-${PROJECT_NAME}"
    else
        print_log -y "[skip] " "Private Subnet already exists: ${PRIVATE_SUBNET_ID}"
    fi

    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --query "InternetGateways[0].InternetGatewayId" --output text)
    if [ "$IGW_ID" == "None" ] || [ -z "$IGW_ID" ]; then
        print_log -c "[create] " "Creating and attaching Internet Gateway..."
        IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
        aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
    else
        print_log -y "[skip] " "Internet Gateway already exists: ${IGW_ID}"
    fi

    NAT_GW_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending" --query "NatGateways[0].NatGatewayId" --output text)
    if [ "$NAT_GW_ID" == "None" ] || [ -z "$NAT_GW_ID" ]; then
        print_log -c "[create] " "Creating NAT Gateway..."
        EIP_ALLOC_ID=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
        NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id $PUBLIC_SUBNET_ID --allocation-id $EIP_ALLOC_ID --query NatGateway.NatGatewayId --output text)
        print_log -y "[wait] " "Waiting for NAT Gateway ($NAT_GW_ID) to become available..."
        aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID
        print_log -g "[ready] " "NAT Gateway is now available."
    else
        print_log -y "[skip] " "NAT Gateway already exists: ${NAT_GW_ID}"
        print_log -y "[verify] " "Ensuring NAT Gateway is available..."
        aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID
    fi

    PUBLIC_RT_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.subnet-id,Values=${PUBLIC_SUBNET_ID}" --query "RouteTables[0].RouteTableId" --output text)
    if [ "$PUBLIC_RT_ID" == "None" ] || [ -z "$PUBLIC_RT_ID" ]; then
        print_log -c "[create] " "Creating and configuring Public Route Table..."
        PUBLIC_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
        aws ec2 create-route --route-table-id $PUBLIC_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
        aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET_ID --route-table-id $PUBLIC_RT_ID
    else
        print_log -y "[skip] " "Public Route Table already exists: ${PUBLIC_RT_ID}"
    fi

    PRIVATE_RT_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.subnet-id,Values=${PRIVATE_SUBNET_ID}" --query "RouteTables[0].RouteTableId" --output text)
    if [ "$PRIVATE_RT_ID" == "None" ] || [ -z "$PRIVATE_RT_ID" ]; then
        print_log -c "[create] " "Creating and configuring Private Route Table..."
        PRIVATE_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
        aws ec2 create-route --route-table-id $PRIVATE_RT_ID --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW_ID
        aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET_ID --route-table-id $PRIVATE_RT_ID
    else
        print_log -y "[skip] " "Private Route Table already exists: ${PRIVATE_RT_ID}"
    fi
    
    # --- Creating VPC Endpoints ---
    print_log -b "[network] " "Creating VPC Endpoints for private access..."
    aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.$AWS_REGION.s3 --route-table-ids $PRIVATE_RT_ID --query 'VpcEndpoint.VpcEndpointId' --output text > /dev/null 2>&1 || print_log -y "[skip] " "S3 Gateway Endpoint may already exist."
    aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.$AWS_REGION.dynamodb --route-table-ids $PRIVATE_RT_ID --query 'VpcEndpoint.VpcEndpointId' --output text > /dev/null 2>&1 || print_log -y "[skip] " "DynamoDB Gateway Endpoint may already exist."

    SG_NAME="${PROJECT_NAME}-endpoints"
    SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
    if [ "$SG_ID" == "None" ] || [ -z "$SG_ID" ]; then
        print_log -c "[create] " "Creating Security Group for Endpoints..."
        SG_ID=$(aws ec2 create-security-group --group-name $SG_NAME --description "SG for interface endpoints for project ${PROJECT_NAME}" --vpc-id $VPC_ID --query GroupId --output text)
        aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 443 --cidr 10.0.0.0/16 > /dev/null 2>&1 || true
    else
        print_log -y "[skip] " "Security Group '${SG_NAME}' already exists: ${SG_ID}"
    fi

    if ! aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.secretsmanager" --query "VpcEndpoints[0].VpcEndpointId" --output text | grep -q vpce; then
        print_log -c "[create] " "Creating Secrets Manager Interface Endpoint..."
        aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.$AWS_REGION.secretsmanager --vpc-endpoint-type Interface --subnet-ids $PRIVATE_SUBNET_ID --security-group-ids $SG_ID
    else
        print_log -y "[skip] " "Secrets Manager Interface Endpoint already exists."
    fi

    # Create Greengrass Security Group
    GG_SG_NAME="${PROJECT_NAME}-greengrass"
    GG_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${GG_SG_NAME}" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
    if [ "$GG_SG_ID" == "None" ] || [ -z "$GG_SG_ID" ]; then
        print_log -c "[create] " "Creating Greengrass Security Group..."
        GG_SG_ID=$(aws ec2 create-security-group --group-name $GG_SG_NAME --description "Security group for Greengrass core devices" --vpc-id $VPC_ID --query GroupId --output text)
        # Allow HTTPS outbound for AWS services
        aws ec2 authorize-security-group-egress --group-id $GG_SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0 > /dev/null 2>&1 || true
        # Allow HTTP outbound for package updates
        aws ec2 authorize-security-group-egress --group-id $GG_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null 2>&1 || true
        # Allow SSH inbound from VPC
        aws ec2 authorize-security-group-ingress --group-id $GG_SG_ID --protocol tcp --port 22 --cidr 10.0.0.0/16 > /dev/null 2>&1 || true
    else
        print_log -y "[skip] " "Greengrass Security Group already exists: ${GG_SG_ID}"
    fi

    print_log -g "[ok] " "VPC Infrastructure setup complete!"
    
    # Export variables for other components
    export VPC_ID PRIVATE_SUBNET_ID PUBLIC_SUBNET_ID SG_ID GG_SG_ID AVAILABILITY_ZONE
}

cleanup_vpc() {
    print_log -b "[delete] " "Cleaning up VPC Infrastructure..."
    validate_inputs
    setup_aws_environment

    print_log -y "[debug] " "Looking for VPC with project name: ${PROJECT_NAME}"
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=${PROJECT_NAME}" --query "Vpcs[0].VpcId" --output text 2>/dev/null)
    if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ] || [ "$VPC_ID" == "null" ]; then
        print_log -y "[info] " "VPC for project '${PROJECT_NAME}' not found."
        return 0
    fi
    print_log -y "[debug] " "Found VPC ID: ${VPC_ID}"

    # Step 1: Delete VPC Endpoints first
    print_log -c "[network] " "Deleting VPC Endpoints..."
    ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" --query "VpcEndpoints[].VpcEndpointId" --output text | tr -s '\t' ' ')
    if [ ! -z "$ENDPOINT_IDS" ] && [ "$ENDPOINT_IDS" != "None" ]; then
        for ENDPOINT_ID in $ENDPOINT_IDS; do
            print_log -c "[delete] " "Deleting VPC Endpoint: $ENDPOINT_ID"
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ENDPOINT_ID 2>/dev/null || true
        done
        print_log -y "[wait] " "Waiting for VPC Endpoints to be fully deleted..."
        while true; do
            REMAINING_ENDPOINTS=$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids $ENDPOINT_IDS --query "VpcEndpoints[?State!='deleted'].VpcEndpointId" --output text 2>/dev/null | tr -s '\t' ' ')
            if [ -z "$REMAINING_ENDPOINTS" ] || [ "$REMAINING_ENDPOINTS" == "None" ]; then
                print_log -g "[ready] " "All VPC Endpoints have been deleted."
                break
            fi
            print_log -y "[waiting] " "Still waiting for endpoints to delete: $REMAINING_ENDPOINTS"
            sleep 10
        done
    fi

    # Step 2: Delete NAT Gateway and release EIP
    print_log -c "[network] " "Deleting NAT Gateway and releasing EIP..."
    NAT_GW_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" --query "NatGateways[?State!='deleted'].NatGatewayId" --output text)
    if [ ! -z "$NAT_GW_ID" ] && [ "$NAT_GW_ID" != "None" ]; then
        EIP_ALLOC_ID=$(aws ec2 describe-nat-gateways --nat-gateway-ids $NAT_GW_ID --query "NatGateways[0].NatGatewayAddresses[0].AllocationId" --output text 2>/dev/null)
        
        print_log -c "[delete] " "Deleting NAT Gateway: $NAT_GW_ID"
        aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW_ID
        print_log -y "[wait] " "Waiting for NAT Gateway to be fully deleted..."
        aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_GW_ID
        print_log -g "[ready] " "NAT Gateway has been deleted."
        if [ ! -z "$EIP_ALLOC_ID" ] && [ "$EIP_ALLOC_ID" != "None" ]; then
            print_log -c "[delete] " "Releasing Elastic IP: $EIP_ALLOC_ID"
            aws ec2 release-address --allocation-id $EIP_ALLOC_ID 2>/dev/null || true
        fi
    fi
    
    print_log -c "[network] " "Checking for orphaned Elastic IPs..."
    ORPHANED_EIPS=$(aws ec2 describe-addresses --query "Addresses[?AssociationId==null].AllocationId" --output text | tr -s '\t' ' ')
    if [ ! -z "$ORPHANED_EIPS" ] && [ "$ORPHANED_EIPS" != "None" ]; then
        for EIP_ID in $ORPHANED_EIPS; do
            print_log -c "[delete] " "Releasing orphaned Elastic IP: $EIP_ID"
            aws ec2 release-address --allocation-id $EIP_ID 2>/dev/null || true
        done
    else
        print_log -y "[skip] " "No orphaned Elastic IPs found."
    fi

    # Step 3: Delete Network Interfaces
    print_log -c "[network] " "Deleting Network Interfaces..."
    ENI_IDS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" --query "NetworkInterfaces[?Status!='deleting'].NetworkInterfaceId" --output text | tr -s '\t' ' ')
    if [ ! -z "$ENI_IDS" ] && [ "$ENI_IDS" != "None" ]; then
        for ENI_ID in $ENI_IDS; do
            print_log -c "[delete] " "Processing Network Interface: $ENI_ID"
            ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null)
            
            if [ ! -z "$ATTACHMENT_ID" ] && [ "$ATTACHMENT_ID" != "None" ] && [ "$ATTACHMENT_ID" != "null" ]; then
                print_log -c "[detach] " "Detaching Network Interface: $ENI_ID (attachment: $ATTACHMENT_ID)"
                aws ec2 detach-network-interface --attachment-id $ATTACHMENT_ID --force 2>/dev/null || true
                sleep 3 
            else
                print_log -y "[info] " "Network Interface $ENI_ID is not attached"
            fi
            
            print_log -c "[delete] " "Deleting Network Interface: $ENI_ID"
            DELETE_RESULT=$(aws ec2 delete-network-interface --network-interface-id $ENI_ID 2>&1)
            if [ $? -ne 0 ]; then
                if echo "$DELETE_RESULT" | grep -q 'does not exist\|NotFound'; then
                    print_log -y "[skip] " "ENI $ENI_ID already deleted"
                elif echo "$DELETE_RESULT" | grep -q 'currently in use'; then
                    print_log -y "[retry] " "ENI $ENI_ID in use - will retry"
                else
                    print_log -r "[error] " "Failed to delete ENI $ENI_ID: $DELETE_RESULT"
                fi
            fi
        done
        
        # Force delete any remaining ENIs immediately, then wait with retry limit
        print_log -y "[wait] " "Checking for remaining Network Interfaces..."
        local wait_count=0
        while true; do
            REMAINING_ENIS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" --query "NetworkInterfaces[?Status!='deleting'].NetworkInterfaceId" --output text 2>/dev/null | tr -s '\t' ' ')
            if [ -z "$REMAINING_ENIS" ] || [ "$REMAINING_ENIS" == "None" ]; then
                print_log -g "[ready] " "All Network Interfaces have been deleted."
                break
            fi
            
            # Handle remaining ENIs based on type
            for STUCK_ENI in $REMAINING_ENIS; do
                ENI_TYPE=$(aws ec2 describe-network-interfaces --network-interface-ids $STUCK_ENI --query "NetworkInterfaces[0].InterfaceType" --output text 2>/dev/null)
                ENI_DESC=$(aws ec2 describe-network-interfaces --network-interface-ids $STUCK_ENI --query "NetworkInterfaces[0].Description" --output text 2>/dev/null)
                
                if [ "$ENI_TYPE" = "lambda" ] && [[ "$ENI_DESC" == *"Lambda"* ]]; then
                    # Extract Lambda function name from description
                    LAMBDA_FUNC=$(echo "$ENI_DESC" | sed 's/.*ENI-\(.*\)/\1/')
                    print_log -c "[lambda] " "Deleting Lambda function to release ENI: $LAMBDA_FUNC"
                    aws lambda delete-function --function-name "$LAMBDA_FUNC" 2>/dev/null || true
                    sleep 3
                else
                    # Try normal detach and delete for non-Lambda ENIs
                    print_log -c "[detach] " "Force detaching ENI: $STUCK_ENI"
                    ATTACHMENT_ID=$(aws ec2 describe-network-interfaces --network-interface-ids $STUCK_ENI --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null)
                    if [ ! -z "$ATTACHMENT_ID" ] && [ "$ATTACHMENT_ID" != "None" ] && [ "$ATTACHMENT_ID" != "null" ]; then
                        aws ec2 detach-network-interface --attachment-id $ATTACHMENT_ID --force 2>/dev/null || true
                    fi
                    print_log -c "[force] " "Force deleting ENI: $STUCK_ENI"
                    aws ec2 delete-network-interface --network-interface-id $STUCK_ENI 2>/dev/null || true
                fi
            done
            
            wait_count=$((wait_count + 1))
            print_log -y "[waiting] " "Still waiting for ENIs to delete: $REMAINING_ENIS (attempt ${wait_count})"
            sleep 5
        done
    else
        print_log -y "[skip] " "No Network Interfaces found to delete."
    fi

    # Step 4: Delete Route Table associations and custom route tables
    print_log -c "[network] " "Deleting Route Tables..."
    ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=false" --query "RouteTables[].RouteTableId" --output text | tr -s '\t' ' ')
    for RT_ID in $ROUTE_TABLE_IDS; do
        if [ "$RT_ID" != "None" ] && [ ! -z "$RT_ID" ]; then
            # Disassociate route table from subnets first
            ASSOCIATIONS=$(aws ec2 describe-route-tables --route-table-ids $RT_ID --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" --output text)
            for ASSOC_ID in $ASSOCIATIONS; do
                if [ "$ASSOC_ID" != "None" ] && [ ! -z "$ASSOC_ID" ]; then
                    aws ec2 disassociate-route-table --association-id $ASSOC_ID 2>/dev/null || true
                fi
            done
            # Delete the route table
            aws ec2 delete-route-table --route-table-id $RT_ID 2>/dev/null || true
        fi
    done

    # Step 5: Detach and delete Internet Gateway
    print_log -c "[network] " "Detaching and deleting Internet Gateway..."
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --query "InternetGateways[0].InternetGatewayId" --output text)
    if [ "$IGW_ID" != "None" ] && [ ! -z "$IGW_ID" ]; then
        print_log -c "[delete] " "Detaching Internet Gateway: $IGW_ID"
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID 2>/dev/null || true
        print_log -y "[wait] " "Waiting for Internet Gateway to be detached..."
        while true; do
            IGW_STATE=$(aws ec2 describe-internet-gateways --internet-gateway-ids $IGW_ID --query "InternetGateways[0].Attachments[0].State" --output text 2>/dev/null)
            if [ "$IGW_STATE" == "None" ] || [ -z "$IGW_STATE" ] || [ "$IGW_STATE" == "detached" ]; then
                print_log -g "[ready] " "Internet Gateway is detached."
                break
            fi
            print_log -y "[waiting] " "Internet Gateway state: $IGW_STATE"
            sleep 5
        done
        print_log -c "[delete] " "Deleting Internet Gateway: $IGW_ID"
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID 2>/dev/null || true
    fi

    # Step 6: Delete Security Groups (except default)
    print_log -c "[network] " "Deleting Security Groups..."
    SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text | tr -s '\t' ' ')
    for SG_ID in $SG_IDS; do
        if [ "$SG_ID" != "None" ] && [ ! -z "$SG_ID" ]; then
            print_log -c "[delete] " "Deleting Security Group: $SG_ID"
            aws ec2 delete-security-group --group-id $SG_ID 2>/dev/null || true
        fi
    done

    # Step 7: Delete Subnets
    print_log -c "[network] " "Deleting Subnets..."
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query "Subnets[].SubnetId" --output text | tr -s '\t' ' ')
    for SUBNET_ID in $SUBNET_IDS; do
        if [ "$SUBNET_ID" != "None" ] && [ ! -z "$SUBNET_ID" ]; then
            print_log -c "[delete] " "Deleting Subnet: $SUBNET_ID"
            aws ec2 delete-subnet --subnet-id $SUBNET_ID 2>/dev/null || true
        fi
    done

    # Step 8: Wait for all subnets to be fully deleted
    print_log -y "[wait] " "Waiting for all subnets to be fully deleted..."
    while true; do
        REMAINING_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query "Subnets[].SubnetId" --output text 2>/dev/null | tr -s '\t' ' ')
        if [ -z "$REMAINING_SUBNETS" ] || [ "$REMAINING_SUBNETS" == "None" ]; then
            print_log -g "[ready] " "All subnets have been deleted."
            break
        fi
        print_log -y "[waiting] " "Still waiting for subnets to delete: $REMAINING_SUBNETS"
        sleep 5
    done

    # Step 9: Finally delete the VPC
    print_log -c "[network] " "Finally, deleting the VPC..."
    while true; do
        if aws ec2 delete-vpc --vpc-id $VPC_ID 2>/dev/null; then
            print_log -g "[ok] " "VPC deleted successfully."
            return 0
        else
            print_log -y "[retry] " "VPC deletion failed, checking for remaining dependencies..."
            
            # Check if VPC still exists
            if ! aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsSupport >/dev/null 2>&1; then
                print_log -g "[ok] " "VPC has been deleted."
                return 0
            fi
            
            # Clean up any remaining security groups
            print_log -y "[cleanup] " "Cleaning up remaining security groups..."
            REMAINING_SGS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null | tr -s '\t' ' ')
            for SG_ID in $REMAINING_SGS; do
                if [ "$SG_ID" != "None" ] && [ ! -z "$SG_ID" ]; then
                    print_log -c "[delete] " "Force deleting remaining Security Group: $SG_ID"
                    aws ec2 delete-security-group --group-id $SG_ID 2>/dev/null || true
                fi
            done
            
            # Clean up any remaining subnets
            REMAINING_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query "Subnets[].SubnetId" --output text 2>/dev/null | tr -s '\t' ' ')
            for SUBNET_ID in $REMAINING_SUBNETS; do
                if [ "$SUBNET_ID" != "None" ] && [ ! -z "$SUBNET_ID" ]; then
                    print_log -c "[delete] " "Force deleting remaining Subnet: $SUBNET_ID"
                    aws ec2 delete-subnet --subnet-id $SUBNET_ID 2>/dev/null || true
                fi
            done
            
            sleep 10
        fi
    done
}

# Main execution
case "${1:-}" in
    setup)
        setup_vpc
        ;;
    cleanup)
        cleanup_vpc
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac