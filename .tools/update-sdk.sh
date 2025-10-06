#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${SCRIPT_DIR}/tmp"
SDK_URL="https://spring-fragrance.mints.ne.jp/aviutl/"

# State files (temporary, in .gitignore)
HTML_FILE="${STATE_DIR}/page.html"
TIMESTAMP_FILE="${STATE_DIR}/detected_timestamp.txt"
ARCHIVE_FILE="${STATE_DIR}/sdk.zip"
EXTRACTION_DONE="${STATE_DIR}/extraction_done.flag"

# Persistent state (committed to repo)
LAST_UPDATE_FILE="${SCRIPT_DIR}/sdk_last_update.txt"

# Create state directory
mkdir -p "${STATE_DIR}"

# Color output helpers
info() {
    echo "[INFO] $*" >&2
}

success() {
    echo "[SUCCESS] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
}

step1_download_html() {
    info "Step 1: Downloading HTML from ${SDK_URL}"

    if [[ -f "${HTML_FILE}" ]]; then
        info "HTML already downloaded. Remove ${HTML_FILE} to re-download."
        return 0
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${SDK_URL}" -o "${HTML_FILE}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "${SDK_URL}" -O "${HTML_FILE}"
    else
        error "Neither curl nor wget found. Please install one of them."
        return 1
    fi

    success "HTML downloaded to ${HTML_FILE}"
}

step2_parse_timestamp() {
    info "Step 2: Parsing HTML for SDK update timestamp"

    if [[ ! -f "${HTML_FILE}" ]]; then
        error "HTML file not found. Run step 1 first."
        return 1
    fi

    if [[ -f "${TIMESTAMP_FILE}" ]]; then
        info "Timestamp already detected: $(cat "${TIMESTAMP_FILE}")"
        return 0
    fi

    # Extract the SDK line from HTML
    # Pattern: <TR ...><TD><A HREF="aviutl2_sdk.zip">...</A></TD><TD>AviUtl ExEdit2 Plugin SDK</TD><TD>2025/10/5</TD></TR>
    local sdk_line
    sdk_line=$(grep 'HREF="aviutl2_sdk.zip"' "${HTML_FILE}")

    if [[ -z "${sdk_line}" ]]; then
        error "Could not find SDK download link in HTML"
        return 1
    fi

    # Extract the date (YYYY/M/D or YYYY/MM/DD format)
    # Last occurrence of date pattern in the line
    local sdk_date
    sdk_date=$(echo "${sdk_line}" | grep -oE '[0-9]{4}/[0-9]{1,2}/[0-9]{1,2}' | tail -n1)

    if [[ -z "${sdk_date}" ]]; then
        error "Could not extract SDK date from HTML"
        return 1
    fi

    # Extract the download URL from HREF attribute
    local sdk_url
    sdk_url=$(echo "${sdk_line}" | grep -oP 'HREF="\K[^"]+' | head -n1)

    if [[ -z "${sdk_url}" ]]; then
        error "Could not extract SDK URL from HTML"
        return 1
    fi

    # Save both timestamp and URL
    echo "${sdk_date}" > "${TIMESTAMP_FILE}"
    echo "${SDK_URL}${sdk_url}" > "${STATE_DIR}/sdk_download_url.txt"

    success "SDK Update Date: ${sdk_date}"
    success "SDK Download URL: ${SDK_URL}${sdk_url}"
}

step3_check_update() {
    info "Step 3: Checking if SDK update is needed"

    if [[ ! -f "${TIMESTAMP_FILE}" ]]; then
        error "Timestamp not detected. Run step 2 first."
        return 1
    fi

    local new_date
    new_date=$(cat "${TIMESTAMP_FILE}")

    local last_date=""
    if [[ -f "${LAST_UPDATE_FILE}" ]]; then
        last_date=$(cat "${LAST_UPDATE_FILE}")
        info "Last applied SDK update: ${last_date}"
    else
        info "No previous SDK update record found."
    fi

    info "Latest SDK update available: ${new_date}"

    if [[ "${new_date}" == "${last_date}" ]]; then
        success "SDK is already up to date (${new_date})"
        return 0
    else
        success "SDK update available: ${last_date:-none} -> ${new_date}"
        return 1  # Return 1 to indicate update is needed
    fi
}

step4_extract_sdk() {
    info "Step 4: Downloading and extracting SDK archive"

    if [[ ! -f "${TIMESTAMP_FILE}" ]]; then
        error "Timestamp not detected. Run step 2 first."
        return 1
    fi

    if [[ ! -f "${STATE_DIR}/sdk_download_url.txt" ]]; then
        error "SDK download URL not found. Run step 2 first."
        return 1
    fi

    local sdk_url
    sdk_url=$(cat "${STATE_DIR}/sdk_download_url.txt")

    # Download the SDK archive if not already downloaded
    if [[ ! -f "${ARCHIVE_FILE}" ]]; then
        info "Downloading SDK from ${sdk_url}..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "${sdk_url}" -o "${ARCHIVE_FILE}"
        elif command -v wget >/dev/null 2>&1; then
            wget -q "${sdk_url}" -O "${ARCHIVE_FILE}"
        else
            error "Neither curl nor wget found. Please install one of them."
            return 1
        fi
        success "SDK archive downloaded to ${ARCHIVE_FILE}"
    else
        info "SDK archive already downloaded."
    fi

    if [[ -f "${EXTRACTION_DONE}" ]]; then
        info "SDK already extracted."
        return 0
    fi

    # Remove old SDK files using git (keeping files starting with .)
    info "Removing old SDK files from git (keeping .* files)..."
    cd "${REPO_ROOT}"

    # Get list of tracked files (excluding .* files)
    local tracked_files
    tracked_files=$(git ls-files | grep -v '^\.')

    if [[ -n "${tracked_files}" ]]; then
        echo "${tracked_files}" | xargs git rm -q --force 2>/dev/null || true
        success "Removed old tracked SDK files"
    else
        info "No tracked SDK files to remove"
    fi

    # Extract the archive
    info "Extracting SDK archive..."
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "${ARCHIVE_FILE}" -d "${REPO_ROOT}"
    else
        error "unzip command not found. Please install unzip."
        return 1
    fi

    # Update the last update file
    local new_date
    new_date=$(cat "${TIMESTAMP_FILE}")
    echo "${new_date}" > "${LAST_UPDATE_FILE}"

    # Stage all new and modified files (respecting .gitignore)
    info "Staging SDK files to git..."
    git add .

    # Show status
    if git diff --cached --quiet; then
        success "No changes detected in SDK files"
    else
        success "SDK files staged for commit"
        git status --short
    fi

    touch "${EXTRACTION_DONE}"
    success "SDK extraction completed"
    success "Updated sdk_last_update.txt to ${new_date}"
}

main() {
    info "Starting SDK update process..."

    # Allow running specific steps
    if [[ $# -gt 0 ]]; then
        case "$1" in
            1|step1)
                step1_download_html
                ;;
            2|step2)
                step2_parse_timestamp
                ;;
            3|step3)
                step3_check_update
                ;;
            4|step4)
                step4_extract_sdk
                ;;
            clean)
                info "Cleaning state directory..."
                rm -rf "${STATE_DIR}"
                success "State cleaned"
                ;;
            *)
                error "Unknown step: $1"
                echo "Usage: $0 [1|2|3|4|clean]"
                return 1
                ;;
        esac
    else
        # Run all steps
        step1_download_html
        step2_parse_timestamp

        # Check if update is needed
        if step3_check_update; then
            info "No update needed. Exiting."
        else
            step4_extract_sdk
            success "SDK updated successfully!"
        fi
    fi
}

main "$@"
