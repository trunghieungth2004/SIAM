#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Documentation Management            |--/ /-|#
#|-/ /--| Converts proposal to DOCX with imgs |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Paths
WORKSPACE_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
DOC_DIR="${WORKSPACE_ROOT}/documentation"
TEMPLATE_DIR="${DOC_DIR}/template"
MATERIAL_DIR="${WORKSPACE_ROOT}/material"
WEBSITE_CONTENT_DIR="${WORKSPACE_ROOT}/website/content"
PROPOSAL_TXT="${DOC_DIR}/SIAM_Proposal.txt"
PROPOSAL_DOCX="${DOC_DIR}/SIAM_Proposal.docx"
PROPOSAL_TEMPLATE="${TEMPLATE_DIR}/Proposal Template.docx"
ARCHITECTURE_DRAWIO="${DOC_DIR}/SIAM_Architecture.drawio"
ARCHITECTURE_PNG="${MATERIAL_DIR}/SIAM_Architecture.png"

# Ensure directories exist
mkdir -p "$DOC_DIR"
mkdir -p "$MATERIAL_DIR"

check_dependencies() {
    print_log -b "[check] " "Checking dependencies..."
    
    local missing_deps=()
    
    # Check for pandoc
    if ! command -v pandoc &> /dev/null; then
        missing_deps+=("pandoc")
    fi
    
    # Check for draw.io (multiple possible names)
    if ! command -v drawio &> /dev/null && \
       ! command -v draw.io &> /dev/null && \
       ! command -v /usr/bin/drawio &> /dev/null && \
       ! command -v /opt/drawio/drawio &> /dev/null; then
        missing_deps+=("drawio")
    fi
    
    # Check for git
    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_log -r "[error] " "Missing dependencies: ${missing_deps[*]}"
        print_log -y "[info] " "Install with: sudo pacman -S ${missing_deps[*]}"
        print_log -y "[info] " "For draw.io: Download from https://github.com/jgraph/drawio-desktop/releases"
        return 1
    fi
    
    print_log -g "[ok] " "All dependencies found"
    return 0
}

detect_drawio_command() {
    # Try various possible locations for draw.io
    if command -v drawio &> /dev/null; then
        echo "drawio"
    elif command -v draw.io &> /dev/null; then
        echo "draw.io"
    elif [ -x "/usr/bin/drawio" ]; then
        echo "/usr/bin/drawio"
    elif [ -x "/opt/drawio/drawio" ]; then
        echo "/opt/drawio/drawio"
    elif [ -x "/Applications/draw.io.app/Contents/MacOS/draw.io" ]; then
        echo "/Applications/draw.io.app/Contents/MacOS/draw.io"
    else
        # Fallback to using draw.io export API
        echo "api"
    fi
}

export_diagram() {
    print_log -c "[export] " "Exporting diagram to PNG..."
    
    if [ ! -f "$ARCHITECTURE_DRAWIO" ]; then
        print_log -r "[error] " "Diagram not found: $ARCHITECTURE_DRAWIO"
        return 1
    fi
    
    local drawio_cmd=$(detect_drawio_command)
    
    if [ "$drawio_cmd" = "api" ]; then
        print_log -y "[fallback] " "Using draw.io web export API..."
        # Use draw.io online export service (4K resolution)
        local encoded_xml=$(cat "$ARCHITECTURE_DRAWIO" | jq -sRr @uri)
        if ! curl -s "https://exp.draw.io/?format=png&w=3840&xml=${encoded_xml}" \
            -o "$ARCHITECTURE_PNG"; then
            print_log -r "[error] " "Failed to export diagram via API"
            return 1
        fi
    else
        print_log -g "[found] " "Using draw.io CLI: $drawio_cmd"
        # Use local draw.io CLI (4K resolution)
        if ! $drawio_cmd --export --format png \
            --width 3840 \
            --transparent \
            --output "$ARCHITECTURE_PNG" \
            "$ARCHITECTURE_DRAWIO" 2>/dev/null; then
            print_log -r "[error] " "Failed to export diagram"
            return 1
        fi
    fi
    
    if [ -f "$ARCHITECTURE_PNG" ]; then
        local size=$(du -h "$ARCHITECTURE_PNG" | cut -f1)
        print_log -g "[ok] " "Diagram exported: $ARCHITECTURE_PNG ($size)"
    else
        print_log -r "[error] " "Export failed - file not created"
        return 1
    fi
}

check_git_changes() {
    print_log -c "[git] " "Checking for changes..."
    
    cd "$WORKSPACE_ROOT"
    
    # Check if proposal.txt exists
    if [ ! -f "$PROPOSAL_TXT" ]; then
        print_log -y "[new] " "Proposal file doesn't exist yet: $PROPOSAL_TXT"
        return 2  # New file
    fi
    
    # Check if file is tracked
    if ! git ls-files --error-unmatch "$PROPOSAL_TXT" &>/dev/null; then
        print_log -y "[new] " "Proposal file is untracked (new)"
        return 2  # Untracked (new)
    fi
    
    # Check for modifications
    if git diff --quiet "$PROPOSAL_TXT" && git diff --cached --quiet "$PROPOSAL_TXT"; then
        print_log -g "[unchanged] " "Proposal file has no changes"
        
        # Also check diagram
        if [ -f "$ARCHITECTURE_DRAWIO" ]; then
            if git diff --quiet "$ARCHITECTURE_DRAWIO" && git diff --cached --quiet "$ARCHITECTURE_DRAWIO"; then
                print_log -g "[unchanged] " "Diagram file has no changes"
                return 0  # No changes
            else
                print_log -y "[modified] " "Diagram file has changes"
                return 1  # Changed
            fi
        fi
        return 0  # No changes
    else
        print_log -y "[modified] " "Proposal file has changes"
        return 1  # Changed
    fi
}

convert_to_docx() {
    print_log -c "[convert] " "Converting proposal to DOCX..."
    
    if [ ! -f "$PROPOSAL_TXT" ]; then
        print_log -r "[error] " "Proposal file not found: $PROPOSAL_TXT"
        return 1
    fi
    
    # Create temporary processed file
    local temp_file="/tmp/siam_proposal_$$.md"
    
    # Process the text file: replace [IMAGE: ...] markers with actual markdown image syntax
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[IMAGE:\ *([^]]+)\] ]]; then
            local image_ref="${BASH_REMATCH[1]}"
            
            # If it's a .drawio file, use the exported PNG
            if [[ "$image_ref" == *".drawio"* ]]; then
                echo "![](${ARCHITECTURE_PNG})"
            else
                # Remove 'material/' prefix if present to avoid double path
                local clean_ref="${image_ref#material/}"
                echo "![](${MATERIAL_DIR}/${clean_ref})"
            fi
        # Add page break after the title page (after date line)
        elif [[ "$line" =~ ^November\ [0-9]+,\ [0-9]{4}$ ]]; then
            echo "$line"
            echo ""
            echo '```{=openxml}'
            echo '<w:p><w:r><w:br w:type="page"/></w:r></w:p>'
            echo '```'
        else
            echo "$line"
        fi
    done < "$PROPOSAL_TXT" > "$temp_file"
    
    # Convert to DOCX with pandoc
    if [ -f "$PROPOSAL_TEMPLATE" ]; then
        print_log -c "[template] " "Using template: $PROPOSAL_TEMPLATE"
        pandoc "$temp_file" \
            --from=markdown \
            --to=docx \
            --output="$PROPOSAL_DOCX" \
            --reference-doc="$PROPOSAL_TEMPLATE"
    else
        print_log -y "[warning] " "Template not found, using default pandoc styling"
        pandoc "$temp_file" \
            --from=markdown \
            --to=docx \
            --output="$PROPOSAL_DOCX"
    fi
    
    if [ -f "$PROPOSAL_DOCX" ]; then
        print_log -g "[ok] " "DOCX created: $PROPOSAL_DOCX"
        local size=$(du -h "$PROPOSAL_DOCX" | cut -f1)
        print_log -m "[size] " "$size"
    else
        print_log -r "[error] " "Failed to convert to DOCX"
        rm -f "$temp_file"
        return 1
    fi
    
    rm -f "$temp_file"
}

create_github_release() {
    print_log -c "[release] " "Creating GitHub release..."
    
    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        print_log -y "[skip] " "GitHub CLI not installed, skipping release creation"
        print_log -y "[info] " "Install with: sudo pacman -S github-cli"
        return 0
    fi
    
    # Check if authenticated
    if ! gh auth status &>/dev/null; then
        print_log -y "[skip] " "GitHub CLI not authenticated, skipping release"
        print_log -y "[info] " "Run: gh auth login"
        return 0
    fi
    
    local tag="proposal-$(date +%Y%m%d-%H%M%S)"
    local release_title="SIAM Proposal - $(date +%Y-%m-%d)"
    
    print_log -c "[create] " "Creating release: $tag"
    
    if gh release create "$tag" \
        "$PROPOSAL_DOCX" \
        "$ARCHITECTURE_PNG" \
        --title "$release_title" \
        --notes "Updated SIAM project proposal with architecture diagram"; then
        
        local download_url="https://github.com/trunghieungth2004/SIAM/releases/download/${tag}/SIAM_Proposal.docx"
        print_log -g "[ok] " "Release created successfully"
        print_log -m "[download] " "$download_url"
        
        # Update proposal.md with new download link
        update_proposal_md "$download_url"
    else
        print_log -r "[error] " "Failed to create release"
        return 1
    fi
}

update_proposal_md() {
    local download_url="$1"
    local proposal_md="${WEBSITE_CONTENT_DIR}/proposal.md"
    
    if [ ! -f "$proposal_md" ]; then
        print_log -y "[skip] " "proposal.md not found, skipping update"
        return 0
    fi
    
    print_log -c "[update] " "Updating proposal.md with download link..."
    
    # Update the download link in proposal.md
    if grep -q "download.*SIAM_Proposal" "$proposal_md"; then
        # Replace existing download link
        sed -i "s|href=\"[^\"]*SIAM_Proposal\.docx\"|href=\"${download_url}\"|g" "$proposal_md"
        print_log -g "[ok] " "Download link updated in proposal.md"
    else
        print_log -y "[skip] " "No download link found in proposal.md"
    fi
}

setup_documentation() {
    print_log -b "[documentation] " "Processing documentation updates..."
    
    # Check dependencies
    if ! check_dependencies; then
        return 1
    fi
    
    # Check for git changes (disable set -e temporarily for this check)
    set +e
    check_git_changes
    local git_status=$?
    set -e
    
    if [ $git_status -eq 0 ]; then
        print_log -g "[skip] " "No changes detected, nothing to do"
        return 0
    fi
    
    # Export diagram if it exists
    if [ -f "$ARCHITECTURE_DRAWIO" ]; then
        if ! export_diagram; then
            print_log -r "[error] " "Failed to export diagram"
            return 1
        fi
    fi
    
    # Convert proposal to DOCX
    if ! convert_to_docx; then
        print_log -r "[error] " "Failed to convert proposal"
        return 1
    fi
    
    # Create GitHub release
    create_github_release || true  # Don't fail if release creation fails
    
    print_log -g "[complete] " "Documentation processing complete!"
    print_log -m "[proposal] " "$PROPOSAL_DOCX"
    print_log -m "[diagram] " "$ARCHITECTURE_PNG"
}

# Main execution (only if run directly, not sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        setup|update)
            if ! setup_documentation; then
                print_log -r "[error] " "Documentation processing failed"
                exit 1
            fi
            ;;
        *)
            echo "Usage: $0 {setup|update}"
            echo ""
            echo "Converts SIAM_Proposal.txt to DOCX with embedded diagrams"
            echo "Creates GitHub release with downloadable documentation"
            exit 1
            ;;
    esac
fi
