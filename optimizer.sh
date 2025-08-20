#!/bin/bash

# Colors
CYAN="\e[96m"
GREEN="\e[92m"
YELLOW="\e[93m"
RED="\e[91m"
BLUE="\e[94m"
MAGENTA="\e[95m"
WHITE="\e[97m"
NC="\e[0m"
BOLD=$(tput bold)

# Message functions
msg_success() { echo -e "${GREEN}[✔] $1${NC}"; }
msg_error()   { echo -e "${RED}[✘] $1${NC}"; }
msg_info()    { echo -e "${CYAN}[i] $1${NC}"; }

# Check if tc command exists
if ! command -v tc &>/dev/null; then
    msg_error "tc command not found! Please install iproute2."
    exit 1
fi

# Function to check qdisc support
check_qdisc_support() {
    local algorithm="$1"
    local iface="${2:-lo}" # Default: loopback

    if tc qdisc add dev "$iface" root "$algorithm" 2>/dev/null; then
        msg_success "$algorithm is supported by kernel on interface $iface"
        tc qdisc del dev "$iface" root 2>/dev/null
        return 0
    else
        msg_error "$algorithm is NOT supported by kernel on interface $iface"
        return 1
    fi
}

# Example: test multiple algorithms
ALGORITHMS=("fq" "fq_codel" "cake" "sfq" "htb")
for algo in "${ALGORITHMS[@]}"; do
    check_qdisc_support "$algo" "lo"
done

ask_bbr_version_1() {
    local backup_file="/etc/sysctl.conf.bak.$(date +%F-%H%M%S)"

    msg_info "Installing and configuring BBRv1 + FQ..."
    
    # Backup original sysctl.conf
    cp /etc/sysctl.conf "$backup_file" || {
        msg_error "Failed to create backup of sysctl.conf"
        return 1
    }

    # Remove old settings if exist
    sed -i '/^net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

    # Apply new settings
    {
        echo "net.core.default_qdisc=fq"
        echo "net.ipv4.tcp_congestion_control=bbr"
    } >> /etc/sysctl.conf

    # Reload sysctl
    if sysctl -p >/dev/null 2>&1; then
        msg_success "BBRv1 + FQ applied successfully."
        msg_info "Active qdisc: $(sysctl net.core.default_qdisc | awk -F= '{print $2}' | xargs)"
        msg_info "Active congestion control: $(sysctl net.ipv4.tcp_congestion_control | awk -F= '{print $2}' | xargs)"
    else
        msg_error "Optimization failed. Restoring original sysctl configuration."
        mv "$backup_file" /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        return 1
    fi
}

fun_bar() {
    local title="$1"
    local command1="$2"
    local command2="$3"
    local tmp_file
    tmp_file=$(mktemp)

    (
        $command1 -y >/dev/null 2>&1
        [[ -n "$command2" ]] && $command2 -y >/dev/null 2>&1
        touch "$tmp_file"
    ) &

    tput civis
    echo -ne "  ${BOLD}${YELLOW}${title}${NC} ${YELLOW}["
    while true; do
        for ((i=0; i<18; i++)); do
            echo -ne "${RED}#"
            sleep 0.2
        done
        if [[ -e "$tmp_file" ]]; then
            rm -f "$tmp_file"
            break
        fi
        echo -e "${YELLOW}]"
        sleep 0.5
        tput cuu1
        tput el
        echo -ne "  ${BOLD}${YELLOW}${title}${NC} ${YELLOW}["
    done
    echo -e "${YELLOW}]${WHITE} - ${GREEN}DONE!${NC}"
    tput cnorm
}

# Must run as root
if [[ $EUID -ne 0 ]]; then
    echo -e "\n ${RED}This script must be run as root.${NC}"
    exit 1
fi

sourcelist() {
    clear
    local title="Source List Adjustment to Official Repositories"
    echo -e "\n${MAGENTA}${title}${NC}\n"
    echo -e "\e[93m+-------------------------------------+\e[0m\n"

    local backup_file="/etc/apt/sources.list.bak.$(date +%F-%H%M%S)"
    cp /etc/apt/sources.list "$backup_file" || {
        msg_error "Error backing up sources.list. Aborting."
        return 1
    }

    get_release_codename() {
        if [[ -f /etc/os-release ]]; then
            source /etc/os-release
            case "$ID" in
                ubuntu|debian)
                    lsb_release -cs
                    ;;
                *)
                    msg_error "Unsupported OS. Cannot determine release codename."
                    return 1
                    ;;
            esac
        else
            msg_error "Unable to detect OS. No changes made."
            return 1
        fi
    }

    release=$(get_release_codename) || return 1

    update_ubuntu_sources() {
        local mirror_url=$1
        local tmp_file
        tmp_file=$(mktemp)
        cat <<EOL > "$tmp_file"
deb $mirror_url $release main restricted universe multiverse
deb $mirror_url $release-updates main restricted universe multiverse
deb $mirror_url $release-backports main restricted universe multiverse
deb $mirror_url $release-security main restricted universe multiverse
EOL
        [[ -s "$tmp_file" ]] || { msg_error "Sources list generation failed."; rm -f "$tmp_file"; return 1; }
        mv "$tmp_file" /etc/apt/sources.list
    }

    update_debian_sources() {
        local mirror_url=$1
        local security_mirror_url=$2
        local tmp_file
        tmp_file=$(mktemp)
        cat <<EOL > "$tmp_file"
deb $mirror_url $release main
deb $mirror_url $release-updates main
deb $mirror_url $release-backports main
deb $security_mirror_url $release-security main
EOL
        [[ -s "$tmp_file" ]] || { msg_error "Sources list generation failed."; rm -f "$tmp_file"; return 1; }
        mv "$tmp_file" /etc/apt/sources.list
    }

    source /etc/os-release
    location_info=$(curl -s --max-time 5 "http://ipwho.is")
    if [[ $? -ne 0 || -z "$location_info" ]]; then
        msg_error "Error fetching location. Defaulting to global mirrors."
        location="Unknown"
    else
        location=$(echo "$location_info" | grep -oP '"country":"\K[^"]+' || echo "Unknown")
    fi

    if [[ "$location" == "Iran" ]]; then
        echo -ne "${YELLOW}Location detected: ${GREEN}Iran${YELLOW}. Use Iranian mirrors? [Y/n]: ${NC}"
    else
        echo -ne "${YELLOW}Location detected: ${GREEN}$location${YELLOW}. Use default mirrors? [Y/n]: ${NC}"
    fi

    read -r update_choice
    case $update_choice in
        [Yy]*|"")
            case "$ID" in
                ubuntu)
                    if [[ "$location" == "Iran" ]]; then
                        update_ubuntu_sources "http://mirror.arvancloud.ir/ubuntu"
                    else
                        update_ubuntu_sources "http://archive.ubuntu.com/ubuntu"
                    fi
                    msg_success "Ubuntu sources list updated."
                    ;;
                debian)
                    if [[ "$location" == "Iran" ]]; then
                        update_debian_sources "http://mirror.arvancloud.ir/debian" "http://mirror.arvancloud.ir/debian-security"
                    else
                        update_debian_sources "http://deb.debian.org/debian" "http://security.debian.org/debian-security"
                    fi
                    msg_success "Debian sources list updated."
                    ;;
                *)
                    msg_error "Unsupported OS detected. No changes made."
                    ;;
            esac
            apt-get update -y && msg_success "Apt cache updated." || msg_error "Failed to update apt cache."
            ;;
        [Nn]*)
            msg_info "Skipping sources list update."
            ;;
        *)
            msg_error "Invalid input. No changes made."
            ;;
    esac
    press_enter
}

press_enter() {
    echo -e "\n${BOLD}${MAGENTA}Press Enter to continue...${NC}"
    read -r _
}

ask_reboot() {
    local choice
    echo -e "\n${YELLOW}Reboot now? (Recommended) ${GREEN}[y/N]${NC}"
    read -r choice

    case "$choice" in
        [Yy]*)
            msg_info "Rebooting system..."
            sleep 1
            systemctl reboot
            ;;
        [Nn]*|"")
            msg_info "Skipping reboot."
            ;;
        *)
            msg_error "Invalid input. Skipping reboot."
            ;;
    esac
}

set_timezone() {
    clear
    local title="Timezone Adjustment"
    echo && printf "${MAGENTA}%s${NC}\n" "$title"
    echo && printf "\e[93m+-------------------------------------+\e[0m\n"

    local current_timezone
    current_timezone=$(timedatectl | awk '/Time zone/ {print $3}')
    msg_info "Your current timezone is ${GREEN}${current_timezone}${NC}"

    # Check dependencies
    if ! command -v curl &>/dev/null; then
        msg_error "curl is not installed. Please install curl to proceed."
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        msg_error "jq is not installed. Please install jq to proceed."
        return 1
    fi

    local sources=("http://ipwho.is" "http://ip-api.com/json")
    local public_ip="" location="" timezone=""

    for source in "${sources[@]}"; do
        local content
        content=$(curl -s --max-time 5 "$source")
        [[ -z "$content" ]] && continue

        case "$source" in
            "http://ipwho.is")
                public_ip=$(echo "$content" | jq -r '.ip' 2>/dev/null)
                location=$(echo "$content" | jq -r '.city' 2>/dev/null)
                timezone=$(echo "$content" | jq -r '.timezone.id' 2>/dev/null | xargs)
                ;;
            "http://ip-api.com/json")
                public_ip=$(echo "$content" | jq -r '.query' 2>/dev/null)
                location=$(echo "$content" | jq -r '.city' 2>/dev/null)
                timezone=$(echo "$content" | jq -r '.timezone' 2>/dev/null | xargs)
                ;;
        esac

        [[ -n "$location" && -n "$timezone" && -n "$public_ip" ]] && break
    done

    if [[ -n "$location" && -n "$timezone" && -n "$public_ip" ]]; then
        msg_info "Your public IP: ${GREEN}$public_ip${NC}"
        msg_info "Detected location: ${GREEN}$location${NC}"
        msg_info "Detected timezone: ${GREEN}$timezone${NC}"

        local date_time
        date_time=$(TZ="$timezone" date "+%Y-%m-%d %H:%M:%S")
        msg_info "Local time in detected timezone: ${GREEN}$date_time${NC}"

        echo -ne "\n${YELLOW}Do you want to apply this timezone? ${GREEN}[y/N]${NC} "
        read -r choice
        case "$choice" in
            [Yy]*)
                if timedatectl set-timezone "$timezone"; then
                    msg_success "Timezone set to $timezone"
                else
                    msg_error "Failed to set timezone."
                fi
                ;;
            *)
                msg_info "Timezone change skipped."
                ;;
        esac
    else
        msg_error "Failed to fetch location/timezone information."
        echo -ne "${YELLOW}Do you want to set timezone manually? ${GREEN}[y/N]${NC} "
        read -r manual_choice
        if [[ "$manual_choice" =~ ^[Yy]$ ]]; then
            timedatectl list-timezones | less
            echo -ne "${CYAN}Enter your desired timezone (e.g., Asia/Tehran): ${NC}"
            read -r manual_tz
            if timedatectl set-timezone "$manual_tz"; then
                msg_success "Timezone set to $manual_tz"
            else
                msg_error "Failed to set timezone manually."
            fi
        fi
    fi

    press_enter
}

spin() {
    SPINNER="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    for i in $(seq 1 30); do
        c=${SPINNER:i%${#SPINNER}:1}
        echo -ne "${RED}${c}${NC}"
        sleep 0.1
        echo -ne "\b"
    done
}

complete_update() {
    clear
    local title="Update and upgrade packages"
    echo -e "\n${CYAN}${title}${NC}"
    echo -e "\n\e[93m+-------------------------------------+\e[0m" 
    echo -e "\n${RED}Please wait, this may take several minutes...${NC}\n"

    (
        apt-get update -y >/dev/null 2>&1
        apt-get upgrade -y >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
        apt-get clean >/dev/null 2>&1
    ) &
    spin $!

    if [[ $? -eq 0 ]]; then
        local updated
        updated=$(apt list --upgradable 2>/dev/null | wc -l)
        msg_success "System update & upgrade completed."
        msg_info "$((updated-1)) packages are up-to-date."
    else
        msg_error "System update failed."
    fi

    echo -ne "\n${YELLOW}Do you want to add static hosts for GitHub mirrors? [y/N]: ${NC}"
    read -r choice
    case "$choice" in
        [Yy]*)
            grep -qxF "140.82.114.4 github.com" /etc/hosts || echo "140.82.114.4 github.com" | tee -a /etc/hosts >/dev/null
            grep -qxF "185.199.108.133 raw.githubusercontent.com" /etc/hosts || echo "185.199.108.133 raw.githubusercontent.com" | tee -a /etc/hosts >/dev/null
            msg_info "Static GitHub hosts added."
            ;;
        *)
            msg_info "Skipped modifying /etc/hosts."
            ;;
    esac

    sleep 1
    press_enter
}

swap_maker() {
    clear
    title="Setup and Configure Swap File to Boost Performance"
    echo -e "\n${MAGENTA}$title${NC}"
    echo -e "\n\e[93m+-------------------------------------+\e[0m"

    existing_swap=$(swapon -s | awk '$1 !~ /^Filename/ {print $1}')
    if [[ -n "$existing_swap" ]]; then
        echo -e "${YELLOW}Removing existing swap files...${NC}"
        for swap_file in $existing_swap; do
            swapoff "$swap_file" 2>/dev/null
            [[ -f "$swap_file" ]] && rm -f "$swap_file"
        done
        sed -i '/ swap /d' /etc/fstab
    fi

    ram_total=$(free -m | awk '/^Mem:/{print $2}')

    if   (( ram_total <= 512 )); then suggested_swap="1G"
    elif (( ram_total <= 2048 )); then suggested_swap="2G"
    elif (( ram_total <= 4096 )); then suggested_swap="4G"
    else suggested_swap="2G"
    fi

    while true; do
        echo -e "\n${CYAN}TIP:${NC} Recommended swap for your RAM ($ram_total MB): ${GREEN}$suggested_swap${NC}"
        echo -e "${YELLOW}Select swap size:${NC}"
        echo -e "0) Auto-detect & use recommended ($suggested_swap)"
        echo -e "1) 512MB"
        echo -e "2) 1GB"
        echo -e "3) 2GB"
        echo -e "4) 4GB"
        echo -e "5) Custom (e.g., 300M, 1G)"
        echo -e "6) No Swap"
        read -r choice
        case $choice in
            0) swap_size="$suggested_swap" ;;
            1) swap_size="512M" ;;
            2) swap_size="1G" ;;
            3) swap_size="2G" ;;
            4) swap_size="4G" ;;
            5) read -p "Enter swap size: " swap_size ;;
            6) echo -e "${RED}No swap will be created.${NC}"; return 0 ;;
            *) echo -e "${RED}Invalid choice.${NC}"; continue ;;
        esac

        if [[ "$swap_size" =~ ^([0-9]+)(M|G)$ ]]; then
            size=${BASH_REMATCH[1]}
            unit=${BASH_REMATCH[2]}
            if [[ "$unit" == "G" ]]; then
                count=$((size * 1024))
            else
                count=$size
            fi
        else
            echo -e "${RED}Invalid format. Use M or G.${NC}"
            return 1
        fi

        available=$(df --output=avail / | tail -n1)
        required=$(( count * 1024 ))
        if (( required > available / 2 )); then
            echo -e "${RED}Swap size too big (more than half of free disk).${NC}"
            return 1
        fi

        swap_file="/swapfile"
        echo -e "${YELLOW}Creating swap file $swap_file of size $swap_size...${NC}"

        if command -v fallocate &>/dev/null; then
            fallocate -l "$swap_size" "$swap_file"
        else
            dd if=/dev/zero of="$swap_file" bs=1M count="$count" status=progress
        fi

        chmod 600 "$swap_file"
        mkswap "$swap_file"
        swapon "$swap_file"

        if ! grep -q "$swap_file" /etc/fstab; then
            echo "$swap_file none swap sw 0 0" >> /etc/fstab
        fi

        swap_value=10
        cache_value=50
        grep -q '^vm.swappiness=' /etc/sysctl.conf \
            && sed -i "s/^vm.swappiness=.*/vm.swappiness=$swap_value/" /etc/sysctl.conf \
            || echo "vm.swappiness=$swap_value" >> /etc/sysctl.conf
        grep -q '^vm.vfs_cache_pressure=' /etc/sysctl.conf \
            && sed -i "s/^vm.vfs_cache_pressure=.*/vm.vfs_cache_pressure=$cache_value/" /etc/sysctl.conf \
            || echo "vm.vfs_cache_pressure=$cache_value" >> /etc/sysctl.conf

        sysctl -p >/dev/null

        echo -e "${GREEN}Swap created: $swap_size, swappiness=$swap_value, vfs_cache_pressure=$cache_value${NC}"
        echo -e "\n${YELLOW}Current memory & swap usage:${NC}"
        free -h

        break
    done
    press_enter
}

swap_maker_1() {
    remove_all_swap() {
        swap_files=$(swapon --show=NAME -h)
        swap_partitions=$(lsblk -o NAME,TYPE | awk '$2=="swap"{print "/dev/" $1}')
        for item in $swap_files $swap_partitions; do
            swapoff "$item"
            [[ -f "$item" ]] && rm -f "$item"
        done
        sed -i '/ swap /d' /etc/fstab
    }
    remove_all_swap

    swap_size="512M"
    dd if=/dev/zero of=/swap bs=1M count=512 status=progress
    chmod 600 /swap
    mkswap /swap
    swapon /swap

    grep -qxF "/swap swap swap defaults 0 0" /etc/fstab || echo "/swap swap swap defaults 0 0" >> /etc/fstab

    swapon --show
    free -h

    swap_value=10
    if grep -q "^vm.swappiness" /etc/sysctl.conf; then
        sed -i "s/^vm.swappiness=.*/vm.swappiness=$swap_value/" /etc/sysctl.conf
    else
        echo "vm.swappiness=$swap_value" >> /etc/sysctl.conf
    fi
    sysctl -p
}

ask_bbr_version() {
    check_Hybla() {
        local param=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
        if [[ x"${param}" == x"hybla" ]]; then
            return 0
        else
            return 1
        fi
    }
   check_os() {
        if _exists "virt-what"; then
            virt="$(virt-what)"
        elif _exists "systemd-detect-virt"; then
            virt="$(systemd-detect-virt)"
        fi
        if [ -n "${virt}" ] && [[ "${virt}" == "lxc" || "${virt}" == "openvz" ]]; then
            echo -e "${RED}Virtualization method ${virt} is not supported.${NC}"
        fi
    }

queuing() {
    while true; do
        echo && echo -e "${CYAN}Select Queuing Algorithm${NC}"
        echo && echo -e "${RED}1. ${CYAN}FQ codel${NC}"
        echo -e "${RED}2. ${CYAN}FQ${NC}"
        echo -e "${RED}3. ${CYAN}Cake${NC}"
        echo -e "${RED}4. ${CYAN}HTB${NC}"
        echo -e "${RED}5. ${CYAN}SFQ${NC}"
        echo -e "${RED}6. ${CYAN}DDR${NC}"
        echo -e "${RED}7. ${CYAN}PFIFO FAST${NC}"
        echo && echo -ne "${YELLOW}Enter your choice [0-3]: ${NC}"
        read -r choice
        case $choice in
            1) algorithm="fq_codel";;
            2) algorithm="fq";;
            3) algorithm="cake";;
            4) algorithm="htb";;
            5) algorithm="sfq";;
            6) algorithm="ddr";;
            7) algorithm="pfifo_fast";;
            0) return 0;;
            *) echo -e "${RED}Invalid choice. Enter 0-3.${NC}"; continue;;
        esac
        if check_qdisc_support "$algorithm"; then
            echo -e "${GREEN}$algorithm will be applied after $MAGENTA reboot the server.${NC}"
            return 0
        else
            echo -e "${RED}$algorithm is not supported. Please select another option.${NC}"
        fi
    done
}
    clear
    title="TCP Congestion Control Optimization"
    echo ""
    echo -e "${MAGENTA}${title}${NC}"
    echo ""
    echo -e "\e[93m+-------------------------------------+\e[0m"
    echo ""
    echo -e "${RED} TIP ! $NC
    $GREEN FQ (Fair Queuing): $NC Allocates bandwidth fairly among flows; good for balancing latency and throughput.
    $GREEN FQ-CoDel: $NC Combines fair queuing with delay management, reducing buffer bloat—suitable for VPNs and general traffic.
    $GREEN CAKE: $NC Manages buffer bloat and bandwidth effectively for WAN links; more CPU-intensive but great for high-latency links.
    $GREEN SFQ (Stochastic Fairness Queuing): $NC Simple fairness-based queuing with low overhead; works well in low-latency setups.
    $GREEN PFIFO_FAST: $NC Simple priority-based queuing, prioritizing critical packets; suitable for basic traffic handling.
    $GREEN DDR (Deficit Round Robin): $NC Balances fairness across flows; good for smooth packet delivery, though less commonly used.
    $GREEN HTB (Hierarchical Token Bucket): $NC Allows bandwidth control with multiple classes; ideal for shaping bandwidth distribution.

    $MAGENTA My Suggestion for VPN servers : $GREEN Fq_codel / sfq / cake $NC"
    echo
    echo -e "${RED}1. ${CYAN} BBR [FQ codel / FQ / cake / Sfq / ddr / htb / pfifo fast] ${NC}"
    echo -e "${RED}2. ${CYAN} BBRv3 [XanMod kernel]${NC}"
    echo -e "${RED}3. ${CYAN} HYBLA [FQ codel / FQ / cake / Sfq / ddr / htb / pfifo fast] ${NC}"
    echo ""
    echo -e "${RED}4. ${CYAN} BBR [OpenVZ] ${NC}"
    echo -e "${RED}0. ${CYAN} Without BBR ${NC}"
    echo ""
    echo -ne "${YELLOW}Enter your choice [0-3]: ${NC}"
    read -r choice

case $choice in
      1)
            cp /etc/sysctl.conf /etc/sysctl.conf.bak
            queuing
            sed -i '/^net.core.default_qdisc/d' /etc/sysctl.conf
            echo "net.core.default_qdisc=$algorithm" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p || mv /etc/sysctl.conf.bak /etc/sysctl.conf
            ;;
    2)
        echo -e "${YELLOW}Installing and configuring XanMod & BBRv3...${NC}"
        if grep -Ei 'ubuntu|debian' /etc/os-release >/dev/null; then
            bash <(curl -s https://raw.githubusercontent.com/arminskuyg31286/VPS-Optimizer/main/bbrv3.sh --ipv4) || { echo -e "${RED}XanMod & BBRv3 installation failed.${NC}"; exit 1; }
            echo -e "${GREEN}XanMod & BBRv3 installation was successful.${NC}"
        else
            echo -e "${RED}This script is intended for Ubuntu or Debian systems only.${NC}"
        fi
        ;;
    3)
        cp /etc/sysctl.conf /etc/sysctl.conf.bak
        check_Hybla
        queuing
        sed -i '/^net.core.default_qdisc/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=$algorithm" >> /etc/sysctl.conf
        sed -i '/^net.ipv4.tcp_congestion_control=/c\net.ipv4.tcp_congestion_control=hybla' /etc/sysctl.conf
        sysctl -p || { echo -e "${RED}Optimization failed. Restoring original sysctl configuration.${NC}"; mv /etc/sysctl.conf.bak /etc/sysctl.conf; }
        echo -e "${GREEN}Kernel parameter optimization for Hybla was successful.${NC}"
        ;;
    4)
        echo -e "${YELLOW}Optimizing kernel parameters for OpenVZ BBR...${NC}"
        if [[ -d "/proc/vz" && -e /sys/class/net/venet0 ]]; then
            cp /etc/sysctl.conf /etc/sysctl.conf.bak
            sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
            sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
            tc qdisc add dev venet0 root fq_codel
            sysctl -w net.ipv4.tcp_congestion_control=bbr || { echo -e "${RED}Optimization failed.${NC}"; mv /etc/sysctl.conf.bak /etc/sysctl.conf; exit 1; }
            sysctl -p
            echo -e "${GREEN}Kernel parameter optimization for OpenVZ was successful.${NC}"
        else
            echo -e "${RED}This system is not OpenVZ or lacks venet0 support. No changes were made.${NC}"
        fi
        ;;
    0)
        echo -e "${YELLOW}No TCP congestion control selected.${NC}"
        ;;
    *)
        echo -e "${RED}Invalid choice. Please enter a number between 0 and 3.${NC}"
        return 1
        ;;
esac
press_enter
}

speedtestcli() {
    if ! command -v speedtest &>/dev/null; then
        if ! command -v curl &>/dev/null; then
            echo -e "${RED}Error: curl is required to add the Speedtest repository.${NC}"
            return 1
        fi

        local pkg_manager=""
        local repo_script=""

        if command -v dnf &>/dev/null; then
            pkg_manager="dnf"
            repo_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
        elif command -v yum &>/dev/null; then
            pkg_manager="yum"
            repo_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
        elif command -v apt-get &>/dev/null; then
            pkg_manager="apt-get"
            repo_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
        else
            echo -e "${RED}Error: Supported package manager not found. Install Speedtest manually.${NC}"
            return 1
        fi

        echo -e "${YELLOW}Adding Speedtest repository...${NC}"
        if curl -s "$repo_script" | sudo bash; then
            echo -e "${GREEN}Repository added successfully.${NC}"
        else
            echo -e "${RED}Failed to add the repository.${NC}"
            return 1
        fi

        echo -e "${YELLOW}Installing Speedtest CLI...${NC}"
        sudo $pkg_manager install -y speedtest
    fi

    if command -v speedtest &>/dev/null; then
        echo -e "${YELLOW}Running Speedtest...${NC}"
        speedtest
    else
        echo -e "${RED}Speedtest is not installed.${NC}"
    fi
}

benchmark() {
    clear
    title="Benchmark (iperf test)"
    echo && echo -e "${MAGENTA}${title}${NC}"
    echo && echo -e "\e[93m+-------------------------------------+\e[0m"
    if ! command -v wget &>/dev/null; then
        echo -e "${YELLOW}Installing wget...${NC}"
        sudo apt-get update && sudo apt-get install wget -y
    fi

    echo && echo -e "${MAGENTA}TIP!${NC}"
    echo -e "${YELLOW}THIS TEST TAKES A LONG TIME, SO PLEASE BE PATIENT${NC}"
    echo && echo -e "${GREEN}Valid Regions: ${YELLOW}na, sa, eu, au, asia, africa, middle-east, india, china, iran${NC}"
    echo && echo -ne "Please type the destination: "
    read -r location

    valid_locations=("na" "sa" "eu" "au" "asia" "africa" "middle-east" "india" "china" "iran")
    if [[ ! " ${valid_locations[*]} " =~ " ${location} " ]]; then
        echo -e "${RED}Invalid region. Please choose a valid one.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Running benchmark test to $location...${NC}"

    if command -v wget &>/dev/null; then
        wget -qO- network-speed.xyz | bash -s -- -r "$location"
    elif command -v curl &>/dev/null; then
        curl -s network-speed.xyz | bash -s -- -r "$location"
    else
        echo -e "${RED}Error: wget or curl is required.${NC}"
        return 1
    fi

    echo && echo -e "${GREEN}Benchmark test completed successfully.${NC}"
    press_enter
}

final() {
    clear
    echo && echo -e "${MAGENTA}Your server fully optimized successfully${NC}"
    echo && echo -e "${MAGENTA}Please reboot the system to take effect, by running the following command: ${GREEN}reboot${NC}" 
    echo && ask_reboot
}

while true; do
    clear
    echo -e "\e[93m+------------------------------------+\e[0m"
    echo -e "       \e[94mVPS OPTIMIZER\e[0m"
    echo -e "\e[93m+------------------------------------+\e[0m"
    echo -e ""
    printf "${GREEN} 1) ${NC}Optimizer (1-click)\n"
    printf "${GREEN} 2) ${NC}Optimizer (step by step)\n"
    echo -e ""
    printf "${GREEN} 3) ${NC}Swap Management\n"
    printf "${GREEN} 4) ${NC}Grub Tuning\n"
    printf "${GREEN} 5) ${NC}BBR Optimization\n"
    echo -e ""
    printf "${GREEN} 6) ${NC}Speedtest\n"
    printf "${GREEN} 7) ${NC}Benchmark VPS\n"
    echo -e ""
    printf "${GREEN} E) ${NC}Exit the menu\n"
    echo
    echo -ne "${GREEN}Select an option: ${NC}"
    read -r choice
    case $choice in
        1)
            clear
            fun_bar "Complete system update and upgrade" complete_update
            fun_bar "Creating swap file with 512MB" swap_maker_1
            ask_bbr_version
            final
            ;;
        2)
            sourcelist
            complete_update
            set_timezone
            swap_maker
            ask_bbr_version
            final
            ;;
        3)
            swap_maker
            ;;
        4)
            grub_tuning
            ;;
        5)
            ask_bbr_version
            ;;
        6)
            speedtestcli
            ;;
        7)
            benchmark
            ;;
        E|e)
            echo && echo -e "${RED}Exiting...${NC}"
            exit 0
            ;;
        *)
            echo && echo -e "${RED}Invalid choice. Please enter a valid option.${NC}"
            ;;
    esac
    echo && echo -e "\n${RED}Press Enter to continue...${NC}"
    read -r
done
