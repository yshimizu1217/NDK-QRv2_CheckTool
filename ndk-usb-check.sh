#!/bin/bash

# Check Device ###

# ID 054c:06c1 Sony Corp. RC-S380/S
# Dev 13, If 0, Class=Vendor Specific Class, Driver=, 12M

# ID 1eab:0006 Fujian Newland Computer Co., Ltd NLS-EM20-80-TW USB CDC
# Dev 11, If 0, Class=Communications, Driver=cdc_acm, 12M
# Dev 11, If 1, Class=CDC Data, Driver=cdc_acm, 12M


# Variables ###

## Sec. Main
readonly LOGFILE=/media/usb1/usb_error.txt
readonly LOOPWAIT=10
readonly FAILURE_COUNT=2
readonly MAX_LOG_SIZE=10000000
readonly REBOOT_FLAG=false

## Sec. NDK Connection Device
declare -rgA USB_NAME=(
  ["IC"]="RC-S380/S"
  ["QR"]="NLS-EM20-80-TW"
)

declare -rgA USB_CheckString=(
  ["IC"]="Specific"
  ["QR"]="CDC"
)

## Sec. ConnectWise Control
readonly CWC_ID="1234567890abcdef"
readonly CWC_PARAM_FILE=/opt/connectwisecontrol-${CWC_ID}/ClientLaunchParameters.txt

## Sec. Slack
readonly SLACK_IS_USE=true
readonly SLACK_HOOK_URL="https://hooks.slack.com/services/XXXXXXXXXX"
readonly SLACK_CH="#random"
readonly SLACK_LAST_ACT=/home/pi/ramdisk/usb_check.slack
readonly SLACK_RECOVERY_NOTICE=true

# Code ###

WriteLog() {
    {
        echo `date '+%Y/%m/%d(%a) %T'` : $1
        if [ $# -gt 1 ]; then
            echo "- - - - - - - - - - - - - -"
        fi
    } >> ${LOGFILE}
    sleep 0.1
}

Check_USB() {
    local IsWorks=true
    lsusb -t | grep ${USB_CheckString["IC"]} > /dev/null
    if [ $? -eq 1 ]; then WriteLog "【${USB_NAME['IC']}】 Not Found"; IsWorks=false; fi

    lsusb -t | grep ${USB_CheckString["QR"]} > /dev/null
    if [ $? -eq 1 ]; then WriteLog "【${USB_NAME['QR']}】 Not Found"; IsWorks=false; fi

    if "${IsWorks}"; then
        return 0
    fi
    return 1
}

USB_ReBIND() {
    local DISK_PORT=`lsusb -t | grep If | grep Storage | awk '{print substr($3,0,1);}'`
    if [ -z ${DISK_PORT} ]; then
        DISK_PORT=0
    fi

    local IC_PORT=`lsusb -t | grep If | grep ${USB_CheckString["IC"]} | awk '{print substr($3,0,1);}'`
    if [ -z ${IC_PORT} ]; then
        IC_PORT=0
    fi

    local QR_PORT=`lsusb -t | grep If | grep ${USB_CheckString["QR"]} | awk '{print substr($3,0,1);}'`
    if [ -z ${QR_PORT} ]; then
        QR_PORT=0
    fi

    for PORT in `seq 4`;  do
        if [ ${PORT} -eq ${DISK_PORT} ] || [ ${PORT} -eq ${IC_PORT} ] || [ ${PORT} -eq ${QR_PORT} ]; then
            continue
        fi
        sudo sh -c "echo -n 1-1.${PORT} >/sys/bus/usb/drivers/usb/unbind" > /dev/null 2>&1
        sudo sh -c "echo -n 1-1.${PORT} >/sys/bus/usb/drivers/usb/bind" > /dev/null 2>&1
        WriteLog "Port:${PORT} bind after unbind"
    done
}

ROTATE_LOG() {
    if [ ! -e ${LOGFILE} ]; then
      return 0
    fi

    local LOG_SIZE=`wc -c ${LOGFILE} | awk '{print $1}'`
    if [ ${MAX_LOG_SIZE} -gt ${LOG_SIZE} ]; then
        return 0
    fi

    mv -f ${LOGFILE} /media/usb1/usb_error.bak
    cat /dev/null > ${LOGFILE} 
}

POST_SLACK() {
    if ! ${SLACK_IS_USE}; then
        return 0
    fi
    if ! "${SLACK_RECOVERY_NOTICE}" && [ "$1" == "OK" ]; then
        return 0
    fi

    local HISTORY=${SLACK_LAST_ACT}
    if [ -e ${HISTORY} ]; then
        local LAST_STATE=`cat ${HISTORY}`
        if [ "${LAST_STATE}" == "NG" ] && [ "$1" == "NG" ]; then
            local time_threshold=$(date -d "30 minutes ago" +%s)
            local file_modified=$(stat -c %Y "${HISTORY}")
            if [[ $file_modified -gt $time_threshold ]]; then
                return 0
            fi
        elif [ "${LAST_STATE}" == "OK" ] && [ "$1" == "OK" ]; then
            return 0
        fi
    else
        if [ "$1" == "OK" ]; then
            echo "OK" > ${HISTORY}
            return 0
        fi
    fi

    local MAC=`/usr/sbin/ifconfig | grep ether | awk '{print $2;}'`
    local CWC_PARAM=`cat ${CWC_PARAM_FILE} | nkf -w --url-input`

    local TEMP_ARRAY=(${CWC_PARAM//&/ })
    local CW_ARRAY
    local temp
    for i in ${TEMP_ARRAY[@]}; do
        temp=`echo $i | cut -f 2 -d "="`
        CW_ARRAY+=("$temp")
    done

    local WEBHOOKURL=${SLACK_HOOK_URL}
    local CHANNEL=${CHANNEL:-"$SLACK_CH"}

    local MESSAGE=""
    for i in `seq 4 8`; do
        if [ "${CW_ARRAY[$i]}" == "" ]; then
            MESSAGE=${MESSAGE}${MAC}
        else
            MESSAGE=${MESSAGE}${CW_ARRAY[$i]}
        fi
        MESSAGE=${MESSAGE}"\n"
    done
    if [ "$1" == "OK" ]; then
        local BOTNAME=${BOTNAME:-"QRv2 正常化"}
        local FACEICON=${FACEICON:-":ok:"}
        echo "OK" > ${HISTORY}
    else
        local BOTNAME=${BOTNAME:-"QRv2 USB-Device 異常発生"}
        local FACEICON=${FACEICON:-":ng:"}
        echo "NG" > ${HISTORY}
    fi

    curl -k -s -S -X POST --data-urlencode "payload={\"channel\": \"${CHANNEL}\", \"username\": \"${BOTNAME}\", \"icon_emoji\": \"${FACEICON}\", \"text\": \"${MESSAGE}${WEBMESSAGE}\" }" ${WEBHOOKURL} >/dev/null
}

ROTATE_LOG
Check_USB
if [ $? -eq 0 ]; then
    touch ${LOGFILE}
    POST_SLACK OK
    exit 0
fi

COUNT=0
while true; do
    USB_ReBIND
    Check_USB
    if [ $? -eq 0 ]; then
        WriteLog "Status OK" PartitionLine
        POST_SLACK OK
        exit 0
    fi

    COUNT=$((COUNT+1))
    WriteLog "Fail Count: ${COUNT}" PartitionLine
    if [ ${COUNT} -ge ${FAILURE_COUNT} ]; then
      break
    fi

    sleep ${LOOPWAIT}
done

WriteLog "Process End: Failed to connect USB device" PartitionLine
POST_SLACK NG
if ${REBOOT_FLAG}; then
    WriteLog "ReBoot" PartitionLine
    sudo /usr/sbin/reboot
fi
exit 1

