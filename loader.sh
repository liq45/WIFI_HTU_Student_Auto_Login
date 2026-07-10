#!/bin/sh

# 网络认证配置
log="captive.log"

# Portal服务器地址
portalServer="http://10.101.2.194:6060"

# 学号（请修改为你的学号）
userid=250408xxxx
# 密码（请修改为你的密码）
password="Myhtu****"
# 运营商后缀，可选值: @htu, @yd, @lt, @dx, @htu.edu.cn
operatorSuffix="@htu"

# 设备信息（固定值和动态获取）
# WiFi接口名称：phy1-sta0 对应 wireless.wifinet1（连接到HTU_Student的客户端接口）
# 确认方法：iw dev 或 uci show wireless | grep HTU_Student
wanInterface="phy1-sta0"
portalURL=""
macAddress=""  # MAC地址（动态获取）
hostname=""  # 主机名（动态获取）
wanIP=""  # IP地址（需动态获取，因为DHCP会变化）

# 从Portal URL中提取的参数
wlanacname=""
wlanacIp=""
vlan=""
portalpageid=""
timestamp=""
uuid=""
version=""

touch ${log}
timemark=$(date +"%Y年%m月%d日 %H:%M:%S")

# 检测HTTP客户端工具（curl或wget）
HTTP_CLIENT=""
HTTP_CLIENT_TYPE=""

if command -v curl >/dev/null 2>&1; then
    HTTP_CLIENT="curl"
    HTTP_CLIENT_TYPE="curl"
elif command -v wget >/dev/null 2>&1; then
    HTTP_CLIENT="wget"
    HTTP_CLIENT_TYPE="wget"
else
    echo "错误: 未找到 curl 或 wget 命令！"
    echo "请安装其中一个工具："
    echo "  opkg update && opkg install curl"
    echo "  或"
    echo "  opkg update && opkg install wget"
    exit 1
fi

echo "使用HTTP客户端: ${HTTP_CLIENT}"

# HTTP请求获取状态码（兼容curl和wget）
# 参数: URL [额外选项]
# 返回: HTTP状态码
http_status_code() {
    local url="$1"
    shift
    local extra_opts="$@"
    
    if [ "${HTTP_CLIENT_TYPE}" = "curl" ]; then
        curl -s --interface ${wanInterface} -o /dev/null -w "%{http_code}" ${extra_opts} "${url}" 2>/dev/null || echo "000"
    elif [ "${HTTP_CLIENT_TYPE}" = "wget" ]; then
        local wget_opts="-q -O /dev/null"
        # 转换超时选项
        if echo "${extra_opts}" | grep -q "connect-timeout"; then
            local timeout=$(echo "${extra_opts}" | grep -o "connect-timeout [0-9]*" | awk '{print $2}')
            if [ -n "${timeout}" ]; then
                wget_opts="${wget_opts} -T ${timeout}"
            fi
        fi
        if echo "${extra_opts}" | grep -q "max-time"; then
            local maxtime=$(echo "${extra_opts}" | grep -o "max-time [0-9]*" | awk '{print $2}')
            if [ -n "${maxtime}" ]; then
                wget_opts="${wget_opts} -T ${maxtime}"
            fi
        fi
        local status=$(wget ${wget_opts} "${url}" 2>&1 | grep -i "HTTP/" | tail -1 | awk '{print $2}')
        echo "${status:-000}"
    fi
}

# HTTP请求获取重定向URL（兼容curl和wget）
# 参数: URL [额外选项]
# 返回: 最终URL
http_redirect_url() {
    local url="$1"
    shift
    local extra_opts="$@"
    
    if [ "${HTTP_CLIENT_TYPE}" = "curl" ]; then
        curl -Ls --interface ${wanInterface} -o /dev/null -w "%{url_effective}" ${extra_opts} "${url}" 2>/dev/null || echo "${url}"
    elif [ "${HTTP_CLIENT_TYPE}" = "wget" ]; then
        local wget_opts="-q -O /dev/null"
        # 转换超时选项
        if echo "${extra_opts}" | grep -q "connect-timeout"; then
            local timeout=$(echo "${extra_opts}" | grep -o "connect-timeout [0-9]*" | awk '{print $2}')
            if [ -n "${timeout}" ]; then
                wget_opts="${wget_opts} -T ${timeout}"
            fi
        fi
        if echo "${extra_opts}" | grep -q "max-time"; then
            local maxtime=$(echo "${extra_opts}" | grep -o "max-time [0-9]*" | awk '{print $2}')
            if [ -n "${maxtime}" ]; then
                wget_opts="${wget_opts} -T ${maxtime}"
            fi
        fi
        local redirect=$(wget ${wget_opts} "${url}" 2>&1 | grep -i "Location:" | tail -1 | awk '{print $2}' | tr -d '\r')
        echo "${redirect:-${url}}"
    fi
}

# URL编码函数（简单版本）
urlencode() {
    echo "$1" | sed 's/@/%40/g; s/:/%3A/g; s/ /%20/g'
}

# 从URL中提取参数值
getUrlParam() {
    local url="$1"
    local param="$2"
    echo "$url" | sed -n "s/.*[?&]${param}=\([^&]*\).*/\1/p" | sed 's/%40/@/g'
}

# 从服务器获取Portal配置（JSON格式）
getPortalConfig() {
    # 从portalURL中提取查询参数
    local queryParams=""
    if echo "${portalURL}" | grep -q '?'; then
        queryParams=$(echo "${portalURL}" | sed 's/.*?//')
    fi
    
    # 构建配置URL
    local configUrl="${portalServer}/PortalJsonAction.do"
    if [ -n "${queryParams}" ]; then
        configUrl="${configUrl}?${queryParams}&viewStatus=1"
    else
        configUrl="${configUrl}?viewStatus=1"
    fi
    
    echo "从服务器获取Portal配置: ${configUrl}"
    
    local jsonResponse=""
    if [ "${HTTP_CLIENT_TYPE}" = "curl" ]; then
        jsonResponse=$(curl -s -L --interface ${wanInterface} "${configUrl}" \
            -H 'Accept: application/json, text/javascript, */*; q=0.01' \
            -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' \
            --connect-timeout 5 \
            --max-time 10 \
            2>/dev/null)
    elif [ "${HTTP_CLIENT_TYPE}" = "wget" ]; then
        jsonResponse=$(wget -q -O - -T 10 "${configUrl}" \
            --header='Accept: application/json, text/javascript, */*; q=0.01' \
            --header='User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' \
            2>/dev/null)
    fi
    
    if [ -n "${jsonResponse}" ]; then
        echo "获取到Portal配置响应"
        
        # 简化JSON以便提取（移除换行和空格，但保留结构）
        local jsonFlat=$(echo "${jsonResponse}" | tr -d '\n\r' | sed 's/[[:space:]]*//g')
        
        # 提取portalpageid (portalconfig.portalconfig.id)
        # 尝试匹配 "portalconfig":{"id":"..." 或 "id":"..."
        local extractedPageid=$(echo "${jsonFlat}" | grep -o '"portalconfig"[^}]*"id"[^"]*"[^"]*"' | grep -o '"id"[^"]*"[^"]*"' | grep -o '"[^"]*"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -z "${extractedPageid}" ]; then
            # 如果上面的方法失败，尝试简单匹配
            extractedPageid=$(echo "${jsonResponse}" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -o '"[^"]*"' | tail -1 | sed 's/"//g')
        fi
        if [ -n "${extractedPageid}" ] && [ "${extractedPageid}" != "null" ] && [ -n "${extractedPageid}" ]; then
            portalpageid="${extractedPageid}"
            echo "从配置获取到portalpageid: ${portalpageid}"
        fi
        
        # 提取timestamp (portalconfig.portalconfig.timestamp)
        local extractedTimestamp=$(echo "${jsonFlat}" | grep -o '"portalconfig"[^}]*"timestamp"[^"]*"[^"]*"' | grep -o '"timestamp"[^"]*"[^"]*"' | grep -o '"[^"]*"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -z "${extractedTimestamp}" ]; then
            extractedTimestamp=$(echo "${jsonResponse}" | grep -o '"timestamp"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -o '"[^"]*"' | tail -1 | sed 's/"//g')
        fi
        if [ -n "${extractedTimestamp}" ] && [ "${extractedTimestamp}" != "null" ] && [ -n "${extractedTimestamp}" ]; then
            timestamp="${extractedTimestamp}"
            echo "从配置获取到timestamp: ${timestamp}"
        fi
        
        # 提取uuid (portalconfig.portalconfig.uuid)
        local extractedUuid=$(echo "${jsonFlat}" | grep -o '"portalconfig"[^}]*"uuid"[^"]*"[^"]*"' | grep -o '"uuid"[^"]*"[^"]*"' | grep -o '"[^"]*"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -z "${extractedUuid}" ]; then
            extractedUuid=$(echo "${jsonResponse}" | grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -o '"[^"]*"' | tail -1 | sed 's/"//g')
        fi
        if [ -n "${extractedUuid}" ] && [ "${extractedUuid}" != "null" ] && [ -n "${extractedUuid}" ]; then
            uuid="${extractedUuid}"
            echo "从配置获取到uuid: ${uuid}"
        fi
        
        # 提取version (portalconfig.serverForm.portalVer)
        local extractedVersion=$(echo "${jsonFlat}" | grep -o '"serverForm"[^}]*"portalVer"[^"]*"[^"]*"' | grep -o '"portalVer"[^"]*"[^"]*"' | grep -o '"[^"]*"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -z "${extractedVersion}" ]; then
            extractedVersion=$(echo "${jsonResponse}" | grep -o '"portalVer"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -o '"[^"]*"' | tail -1 | sed 's/"//g')
        fi
        if [ -n "${extractedVersion}" ] && [ "${extractedVersion}" != "null" ] && [ -n "${extractedVersion}" ]; then
            version="${extractedVersion}"
            echo "从配置获取到version: ${version}"
        fi
    else
        echo "警告: 无法从服务器获取Portal配置，将使用默认值"
    fi
}

# 获取设备信息（动态获取IP、MAC和主机名）
function GetDeviceInfo {
    echo "开始获取设备信息..."
    echo "尝试从接口 ${wanInterface} 获取IP和MAC地址..."
    
    # 优先从phy1-sta0接口获取MAC地址（使用iw命令，更准确）
    if command -v iw &> /dev/null; then
        macAddress=$(iw dev ${wanInterface} info 2>/dev/null | grep "addr" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
        if [ -n "${macAddress}" ]; then
            echo "从 iw dev ${wanInterface} 获取到MAC地址: ${macAddress}"
        fi
    fi
    
    # 如果iw命令失败，使用ip命令获取MAC地址
    if [ -z "${macAddress}" ] && command -v ip &> /dev/null; then
        macAddress=$(ip link show ${wanInterface} 2>/dev/null | grep "ether" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
        if [ -n "${macAddress}" ]; then
            echo "从 ip link show ${wanInterface} 获取到MAC地址: ${macAddress}"
        fi
    fi
    
    # 如果还是失败，使用ifconfig获取MAC地址
    if [ -z "${macAddress}" ]; then
        macAddress=$(ifconfig ${wanInterface} 2>/dev/null | grep "HWaddr\|ether" | awk '{print $NF}' | tr '[:upper:]' '[:lower:]')
        if [ -n "${macAddress}" ]; then
            echo "从 ifconfig ${wanInterface} 获取到MAC地址: ${macAddress}"
        fi
    fi
    
    # 获取WAN口IP（只从指定的wanInterface接口获取，不尝试其他接口）
    if command -v ip &> /dev/null; then
        wanIP=$(ip addr show ${wanInterface} 2>/dev/null | grep "inet " | head -1 | awk '{print $2}' | cut -d'/' -f1)
        if [ -n "${wanIP}" ]; then
            echo "从 ${wanInterface} 获取到IP: ${wanIP}"
        fi
    fi
    
    # 尝试从ifconfig获取（仅从wanInterface接口）
    if [ -z "${wanIP}" ]; then
        wanIP=$(ifconfig ${wanInterface} 2>/dev/null | grep "inet addr" | cut -d: -f2 | cut -d' ' -f1)
        if [ -n "${wanIP}" ]; then
            echo "从ifconfig ${wanInterface} 获取到IP: ${wanIP}"
        fi
    fi
    
    # 如果接口没有IP地址，等待一段时间让DHCP分配（最多等待10秒）
    if [ -z "${wanIP}" ]; then
        echo "接口 ${wanInterface} 当前没有IP地址，等待DHCP分配..."
        waitCount=0
        maxWait=10  # 最多等待10次（每次1秒）
        while [ ${waitCount} -lt ${maxWait} ] && [ -z "${wanIP}" ]; do
            sleep 1
            waitCount=$((waitCount + 1))
            if command -v ip &> /dev/null; then
                wanIP=$(ip addr show ${wanInterface} 2>/dev/null | grep "inet " | head -1 | awk '{print $2}' | cut -d'/' -f1)
            fi
            if [ -z "${wanIP}" ]; then
                wanIP=$(ifconfig ${wanInterface} 2>/dev/null | grep "inet addr" | cut -d: -f2 | cut -d' ' -f1)
            fi
            if [ -n "${wanIP}" ]; then
                echo "等待 ${waitCount} 秒后，从 ${wanInterface} 获取到IP: ${wanIP}"
                break
            fi
        done
        
        if [ -z "${wanIP}" ]; then
            echo "提示: ${wanInterface} 接口在等待 ${maxWait} 秒后仍未获取到IP地址"
            echo "这可能是正常的（需要先通过Portal认证才能分配IP）"
            echo "将尝试使用空IP地址进行认证，服务器可能会返回正确的IP"
        fi
    fi
    
    # 获取主机名
    hostname=$(uci get system.@system[0].hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo 'OpenWrt')
    
    echo "========================================"
    echo "设备信息获取结果:"
    echo "  MAC地址: ${macAddress:-未获取}"
    echo "  IP地址: ${wanIP:-未获取（可能未认证）}"
    echo "  主机名: ${hostname}"
    echo "  使用接口: ${wanInterface}"
    echo "========================================"
    
    if [ -z "${macAddress}" ]; then
        echo "错误: 无法从 ${wanInterface} 获取MAC地址！"
        echo "请检查接口 ${wanInterface} 是否存在："
        echo "  iw dev"
        echo "  ip link show ${wanInterface}"
    fi
    if [ -z "${wanIP}" ]; then
        echo "提示: ${wanInterface} 接口当前没有IP地址（可能还未认证，这是正常的）"
        echo "认证后IP地址将从Portal URL中获取"
    fi
}

# 检查网络连接
function ConnectionCheck {
    # 使用baidu.com检测网络连接
    httpCode=$(http_status_code "http://www.baidu.com" "--connect-timeout 10 --max-time 10")
    if [ "${httpCode}" = "200" ]; then
        connection="1"
    else
        
        echo "尝试ping检测网络连接..."
        if ping -c 1 -W 3 114.114.114.114 >/dev/null 2>&1 || ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1; then
            connection="1"
        else
            connection="0"
        fi
    fi
}

# 获取Portal页面并解析参数
function GetPortalPage {
    # 尝试访问一个会被重定向到Portal的URL
    echo "尝试获取Portal页面..."
    redirectURL=$(http_redirect_url "http://www.gstatic.com/generate_204" "--connect-timeout 5 --max-time 5")
    
    case "${redirectURL}" in
        http://10.101.2.194:6060/portal*)
            portalURL="${redirectURL}"
            echo "获取到Portal URL: ${portalURL}"
            
            # 从Portal URL中提取参数（优先使用Portal URL中的IP）
            portalIP=$(getUrlParam "${portalURL}" "wlanuserip")
            if [ -n "${portalIP}" ]; then
                echo "从Portal URL提取到IP: ${portalIP}"
                wanIP="${portalIP}"
            fi
            
            wlanacname=$(getUrlParam "${portalURL}" "wlanacname")
            wlanacIp=$(getUrlParam "${portalURL}" "wlanacIp")
            vlan=$(getUrlParam "${portalURL}" "vlan")
            
            # 如果URL中没有这些参数，尝试访问Portal页面获取
            if [ -z "${wlanacname}" ] || [ -z "${wlanacIp}" ] || [ -z "${vlan}" ]; then
                echo "从Portal URL提取参数不完整，尝试访问Portal页面..."
                if [ "${HTTP_CLIENT_TYPE}" = "curl" ]; then
                    portalContent=$(curl -s -L --interface ${wanInterface} "${portalURL}" \
                        -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
                        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' \
                        2>/dev/null)
                elif [ "${HTTP_CLIENT_TYPE}" = "wget" ]; then
                    portalContent=$(wget -q -O - "${portalURL}" \
                        --header='Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
                        --header='User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' \
                        2>/dev/null)
                fi
                
                # 尝试从页面内容中提取参数（如果URL中没有）
                if [ -z "${wlanacname}" ]; then
                    wlanacname=$(echo "${portalContent}" | grep -o 'wlanacname[=:][^"& ]*' | cut -d'=' -f2 | cut -d'"' -f1 | head -1)
                fi
                if [ -z "${wlanacIp}" ]; then
                    wlanacIp=$(echo "${portalContent}" | grep -o 'wlanacIp[=:][^"& ]*' | cut -d'=' -f2 | cut -d'"' -f1 | head -1)
                fi
                if [ -z "${vlan}" ]; then
                    vlan=$(getUrlParam "${portalURL}" "vlan")
                fi
            fi
            
            # 如果仍然没有，使用默认值或从URL构造的参数
            if [ -z "${wlanacname}" ]; then
                wlanacname="HSD-BRAS-2"
            fi
            if [ -z "${wlanacIp}" ]; then
                wlanacIp="10.101.2.36"
            fi
            if [ -z "${vlan}" ]; then
                vlan=$(getUrlParam "${portalURL}" "vlan")
                if [ -z "${vlan}" ]; then
                    vlan="19953614"  # 使用默认值，实际应该从Portal获取
                fi
            fi
            
            # 从服务器获取Portal配置（timestamp、uuid、portalpageid、version等）
            getPortalConfig
            
            # 如果从服务器获取失败，使用默认值
            if [ -z "${portalpageid}" ]; then
                portalpageid="81"  # 默认值
            fi
            if [ -z "${version}" ]; then
                version="0"  # 默认值
            fi
            
            echo "解析的参数: wlanacname=${wlanacname}, wlanacIp=${wlanacIp}, vlan=${vlan}, portalpageid=${portalpageid}, version=${version}"
            return 0
            ;;
        *)
            # 如果无法自动获取，尝试直接访问Portal服务器获取重定向
            echo "无法通过generate_204获取重定向，尝试直接访问Portal服务器..."
            if [ -n "${macAddress}" ] && [ -n "${hostname}" ]; then
                # 构造一个基本的Portal URL（即使没有IP也尝试）
                tempPortalURL="${portalServer}/portal.do?wlanuserip=${wanIP}&wlanacname=HSD-BRAS-2&mac=${macAddress}&vlan=19953614&hostname=${hostname}"
                echo "尝试访问: ${tempPortalURL}"
                
                # 尝试访问这个URL获取重定向
                newRedirectURL=$(http_redirect_url "${tempPortalURL}" "--connect-timeout 5 --max-time 5")
                
                # 清理可能的重复URL（如果返回的是原始URL+重定向URL的组合）
                newRedirectURL=$(echo "${newRedirectURL}" | sed 's/http:\/\/[^ ]*http:\/\//http:\/\//' | head -1)
                
                if echo "${newRedirectURL}" | grep -q "10.101.2.194:6060/portal"; then
                    portalURL="${newRedirectURL}"
                    echo "通过直接访问获取到Portal URL: ${portalURL}"
                    
                    # 从Portal URL中提取IP
                    portalIP=$(getUrlParam "${portalURL}" "wlanuserip")
                    if [ -n "${portalIP}" ]; then
                        echo "从Portal URL提取到IP: ${portalIP}"
                        wanIP="${portalIP}"
                    fi
                    
                    wlanacname=$(getUrlParam "${portalURL}" "wlanacname")
                    wlanacIp=$(getUrlParam "${portalURL}" "wlanacIp")
                    vlan=$(getUrlParam "${portalURL}" "vlan")
                else
                    # 如果还是失败，使用默认值构造
                    portalURL="${tempPortalURL}"
                    echo "无法获取Portal重定向，使用默认参数构造URL"
                fi
            else
                # 如果没有MAC地址，使用默认值构造
                portalURL="${portalServer}/portal.do?wlanuserip=${wanIP}&wlanacname=HSD-BRAS-2&mac=${macAddress}&vlan=19953614&hostname=${hostname}"
                echo "使用构造的Portal URL和默认参数: ${portalURL}"
            fi
            
            # 设置默认值
            if [ -z "${wlanacname}" ]; then
                wlanacname="HSD-BRAS-2"
            fi
            if [ -z "${wlanacIp}" ]; then
                wlanacIp="10.101.2.36"
            fi
            if [ -z "${vlan}" ]; then
                vlan="19953614"
            fi
            
            # 尝试从服务器获取Portal配置
            getPortalConfig
            
            # 如果从服务器获取失败，使用默认值
            if [ -z "${portalpageid}" ]; then
                portalpageid="81"
            fi
            if [ -z "${version}" ]; then
                version="0"
            fi
            
            echo "解析的参数: wlanacname=${wlanacname}, wlanacIp=${wlanacIp}, vlan=${vlan}, portalpageid=${portalpageid}, version=${version}"
            return 1
            ;;
    esac
}

# 生成UUID（简单版本，兼容BusyBox）
generateUUID() {
    # 方法1: 使用 /dev/urandom（如果可用）
    if [ -c /dev/urandom ]; then
        # 读取16字节并转换为hex，使用cut提取各部分
        hex=$(od -A n -t x1 -N 16 /dev/urandom 2>/dev/null | tr -d ' \n')
        if [ -n "${hex}" ]; then
            part1=$(echo "${hex}" | cut -c1-8)
            part2=$(echo "${hex}" | cut -c9-12)
            part3=$(echo "${hex}" | cut -c13-16)
            part4=$(echo "${hex}" | cut -c17-20)
            part5=$(echo "${hex}" | cut -c21-32)
            if [ -n "${part1}" ] && [ -n "${part5}" ]; then
                echo "${part1}-${part2}-${part3}-${part4}-${part5}"
                return 0
            fi
        fi
    fi
    
    # 方法2: 使用时间戳和随机数组合（完全BusyBox兼容）
    timestamp=$(date +%s)
    # 生成多个随机数
    r1=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    r2=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    r3=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    r4=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    r5=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    r6=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    
    # 构建UUID格式: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    # 将时间戳转换为8位hex
    ts_hex=$(printf "%08x" $((timestamp % 4294967296)))
    echo "${ts_hex}-${r1}-${r2}-${r3}-${r4}${r5}${r6}"
}

# 认证请求（模拟浏览器行为，使用quickauth.do）
function Auth {
    echo "步骤1: 准备认证参数..."
    
    # 检查IP地址（如果没有IP，仍然尝试认证，服务器可能会返回正确的IP）
    if [ -z "${wanIP}" ]; then
        echo "警告: IP地址为空，但仍将尝试认证（服务器可能会返回正确的IP）"
        echo "提示: 如果认证失败，可能是因为接口还未获取到IP地址"
    fi
    
    # 检查MAC地址
    if [ -z "${macAddress}" ]; then
        echo "警告: MAC地址为空，可能影响认证"
    fi
    
    # 如果timestamp和uuid为空（未从服务器获取），则生成
    if [ -z "${timestamp}" ]; then
        echo "警告: timestamp为空，生成时间戳..."
        sec_timestamp=$(date +%s)
        if [ -n "${sec_timestamp}" ]; then
            timestamp="${sec_timestamp}000"
        else
            timestamp=$(awk 'BEGIN{srand();print int(rand()*10000000000000)}')
        fi
    fi
    
    if [ -z "${uuid}" ]; then
        echo "警告: uuid为空，生成UUID..."
        uuid=$(generateUUID)
    fi
    
    # 如果version为空，使用默认值
    if [ -z "${version}" ]; then
        version="0"
    fi
    
    # URL编码参数
    encodedUserid=$(urlencode "${userid}${operatorSuffix}")
    encodedMac=$(urlencode "${macAddress}")
    encodedHostname=$(urlencode "${hostname}")
    
    # 构建quickauth.do URL（GET请求，所有参数在URL中）
    # 注意：添加wlanuseripv6参数（虽然可能为空，但portalUtil.js中包含此参数）
    # 即使wanIP为空，也发送请求（服务器可能会告诉我们正确的IP）
    authUrl="${portalServer}/quickauth.do?userid=${encodedUserid}&passwd=${password}&wlanuserip=${wanIP}&wlanuseripv6=&wlanacname=${wlanacname}&wlanacIp=${wlanacIp}&ssid=&vlan=${vlan}&mac=${encodedMac}&version=${version}&portalpageid=${portalpageid}&timestamp=${timestamp}&uuid=${uuid}&portaltype=0&hostname=${encodedHostname}&bindCtrlId="
    
    echo "步骤2: 发送认证请求..."
    echo "使用的参数:"
    echo "  IP地址: ${wanIP}"
    echo "  MAC地址: ${macAddress}"
    echo "  主机名: ${hostname}"
    echo "  AC名称: ${wlanacname}"
    echo "  AC IP: ${wlanacIp}"
    echo "  VLAN: ${vlan}"
    echo "认证URL: ${authUrl}"
    
    # 发送GET请求（模拟浏览器）
    echo "发送HTTP请求..."
    
    # 先尝试正常请求获取响应（绑定到正确的网络接口）
    if [ "${HTTP_CLIENT_TYPE}" = "curl" ]; then
        # 如果接口有IP地址，绑定到接口；否则绑定到接口名称
        local bindOption=""
        if [ -n "${wanIP}" ]; then
            bindOption="--interface ${wanInterface}"
        else
            bindOption="--interface ${wanInterface}"
        fi
        
        responseBody=$(curl -s -L ${bindOption} "${authUrl}" \
            -H 'Accept: application/json, text/javascript, */*; q=0.01' \
            -H 'Accept-Encoding: gzip, deflate' \
            -H 'Accept-Language: zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6' \
            -H 'Connection: keep-alive' \
            -H "Host: 10.101.2.194:6060" \
            -H "Referer: ${portalURL:-${portalServer}/portal.do}" \
            -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0' \
            -H 'X-Requested-With: XMLHttpRequest' \
            -H "Cookie: macAuth=${macAddress}" \
            --connect-timeout 10 \
            --max-time 30 \
            --compressed \
            -w "\nHTTP_CODE:%{http_code}" \
            2>/dev/null)
        
        # 提取HTTP状态码和响应体
        httpCode=$(echo "${responseBody}" | grep "HTTP_CODE:" | cut -d: -f2)
        responseBody=$(echo "${responseBody}" | grep -v "HTTP_CODE:")
        
        # 如果没有响应，尝试获取错误信息
        if [ -z "${responseBody}" ] || [ "${responseBody}" = "HTTP_CODE:" ]; then
            echo "警告: 未收到响应，尝试获取详细错误信息..."
            errorInfo=$(curl -s -L --interface ${wanInterface} "${authUrl}" \
                -H 'Accept: application/json, text/javascript, */*; q=0.01' \
                -H "Referer: ${portalURL:-${portalServer}/portal.do}" \
                -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0' \
                --connect-timeout 10 \
                --max-time 30 \
                -w "\nHTTP_CODE:%{http_code}\nERROR:%{errormsg}" \
                2>&1)
            responseBody=$(echo "${errorInfo}" | grep -v "HTTP_CODE:" | grep -v "ERROR:")
            httpCode=$(echo "${errorInfo}" | grep "HTTP_CODE:" | cut -d: -f2)
            if [ -z "${responseBody}" ]; then
                responseBody="请求失败: $(echo "${errorInfo}" | grep "ERROR:" | cut -d: -f2-)"
            fi
        fi
    elif [ "${HTTP_CLIENT_TYPE}" = "wget" ]; then
        # 使用wget发送请求（绑定到接口IP）
        local wgetBindOpt=""
        if [ -n "${wanIP}" ]; then
            wgetBindOpt=""
        fi
        responseBody=$(wget -q -O - -T 30 ${wgetBindOpt} "${authUrl}" \
            --header='Accept: application/json, text/javascript, */*; q=0.01' \
            --header='Accept-Language: zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6' \
            --header='Connection: keep-alive' \
            --header="Host: 10.101.2.194:6060" \
            --header="Referer: ${portalURL:-${portalServer}/portal.do}" \
            --header='User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0' \
            --header='X-Requested-With: XMLHttpRequest' \
            --header="Cookie: macAuth=${macAddress}" \
            2>&1)
        
        # wget不直接提供HTTP状态码，需要从响应中提取或使用-S选项
        if echo "${responseBody}" | grep -qi "error\|failed\|无法连接"; then
            httpCode="000"
            if [ -z "${responseBody}" ] || echo "${responseBody}" | grep -qi "error\|failed"; then
                echo "警告: 未收到响应，尝试获取详细错误信息..."
                errorInfo=$(wget -q -O - -T 30 "${authUrl}" \
                    --header='Accept: application/json, text/javascript, */*; q=0.01' \
                    --header="Referer: ${portalURL:-${portalServer}/portal.do}" \
                    --header='User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0' \
                    2>&1)
                httpCode=$(echo "${errorInfo}" | grep -i "HTTP/" | tail -1 | awk '{print $2}')
                responseBody=$(echo "${errorInfo}" | grep -v "HTTP/" | grep -v "^$")
                if [ -z "${responseBody}" ]; then
                    responseBody="请求失败: ${errorInfo}"
                fi
            fi
        else
            # 尝试获取HTTP状态码
            httpCode=$(wget -q -O /dev/null "${authUrl}" \
                --header='Accept: application/json, text/javascript, */*; q=0.01' \
                --header="Referer: ${portalURL:-${portalServer}/portal.do}" \
                --header='User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0' \
                2>&1 | grep -i "HTTP/" | tail -1 | awk '{print $2}')
            if [ -z "${httpCode}" ]; then
                httpCode="200"  # 假设成功
            fi
        fi
    fi
    
    # 步骤3: 处理返回结果
    echo "HTTP状态码: ${httpCode:-未知}"
    echo "认证响应: ${responseBody:-无响应}"
    authResult="${responseBody:-无响应}"
    
    # 检查响应是否成功（根据portalUtil.js，code="0"表示认证成功）
    if echo "${responseBody}" | grep -qi '"code":"0"\|"code":0'; then
        echo "步骤3: 认证成功 (code=0)"
        message=$(echo "${responseBody}" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        if [ -n "${message}" ] && [ "${message}" != "null" ]; then
            authResult="认证成功: ${message}"
        else
            authResult="认证成功: ${responseBody}"
        fi
    elif echo "${responseBody}" | grep -qi '"result":"success"\|"code":"1"\|"code":1\|success\|成功'; then
        echo "步骤3: 认证成功"
        authResult="认证成功: ${responseBody}"
    elif echo "${responseBody}" | grep -qi '"result":"fail"\|"code":"-1"\|"code":-1\|fail\|失败'; then
        echo "步骤3: 认证失败"
        authResult="认证失败: ${responseBody}"
    else
        echo "步骤3: 认证响应: ${responseBody}"
        authResult="认证响应: ${responseBody}"
    fi
}

# 日志记录
function Logger {
    if [ "${connection}" = "1" ]; then
        if [ "${authResult}" = "网络已连接，无需认证" ]; then
            result="网络已连接，无需认证"
        else
            result="网络正常"
        fi
    else
        # 使用case语句进行模式匹配（ash兼容）
        case "${authResult}" in
            *"已经在线"*|*"已登录"*)
                result="当前设备已登录"
                ;;
            *'"code":"1"'*|*'"code":1'*)
                result="认证检查成功"
                ;;
            *'"code":"0"'*|*'"code":0'*|*"认证成功"*)
                # code="0"表示认证成功（根据portalUtil.js）
                result="认证成功"
                ;;
            *'"code":"-1"'*|*'"code":-1'*)
                result="认证失败，服务器返回code=-1"
                ;;
            *'result":"success'*)
                result="认证成功"
                ;;
            *'用户数量上限'*|*'用户在线数'*)
                result="其他设备已登录"
                ;;
            *'欠费'*)
                result="账户已欠费"
                ;;
            *'密码'*|*'username'*)
                result="用户名或密码错误"
                ;;
            *'msg'*)
                # 提取错误消息（使用BusyBox兼容的方法）
                msg=$(echo "${authResult}" | grep '"msg":"' | cut -d'"' -f4)
                if [ -n "${msg}" ]; then
                    result="认证失败: ${msg}"
                else
                    result="认证失败"
                fi
                ;;
            *)
                if [ -z "${authResult}" ]; then
                    result="认证失败：网络无响应"
                else
                    result="认证失败，服务器返回: ${authResult}"
                fi
                ;;
        esac
    fi
    printf "--------------------------------\n操作时间: %s\n网络状态: %s\n响应详情: %s\n\n" "${timemark}" "${result}" "${authResult}" >>${log}
}

# 日志清理（每月1号清空）
function Clog {
    if [ "$(date +"%d")" = "01" ]; then
        printf "日志已经在%s刷新\n\n" "${timemark}" >${log}
    fi
}

# 主运行函数
function Run {
    # 初始化
    authResult=""
    
    # 首先检查网络连接状态
    echo "检查网络连接状态..."
    ConnectionCheck
    
    # 如果网络畅通，直接退出，无需执行登录操作
    if [ "${connection}" = "1" ]; then
        echo "网络连接正常，无需执行认证操作"
        authResult="网络已连接，无需认证"
        Logger
        Clog
        cat ${log}
        exit 0
    fi
    
    # 网络不通，继续执行认证流程
    echo "网络未连接，开始认证流程..."
    
    # 获取设备信息
    GetDeviceInfo
    
    # 检查Portal认证状态
    echo "检查Portal认证状态..."
    GetPortalPage
    
    # 执行认证操作
    echo "执行认证..."
    Auth
    
    Logger
    Clog
    cat ${log}
    exit 0
}

Run
