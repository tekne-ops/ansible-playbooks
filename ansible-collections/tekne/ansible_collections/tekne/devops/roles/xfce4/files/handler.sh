#!/bin/bash
# Default acpi script that takes an entry for all actions


fxply () {
    sudo -u dvaliente env -i bash -c "XDG_RUNTIME_DIR='/run/user/1000' DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus' $1"
    return 0
}


case "$1" in
    # button/power)
    #     case "$2" in
    #         PBTN|PWRF)
    #             logger 'PowerButton pressed'
    #             ;;
    #         *)
    #             logger "ACPI action undefined: $2"
    #             ;;
    #     esac
    #     ;;
    # button/sleep)
    #     case "$2" in
    #         SLPB|SBTN)
    #             logger 'SleepButton pressed'
    #             ;;
    #         *)
    #             logger "ACPI action undefined: $2"
    #             ;;
    #     esac
    #     ;;
    # ac_adapter)
    #     case "$2" in
    #         AC|ACAD|ADP0)
    #             case "$4" in
    #                 00000000)
    #                     logger 'AC unpluged'
    #                     ;;
    #                 00000001)
    #                     logger 'AC pluged'
    #                     ;;
    #             esac
    #             ;;
    #         *)
    #             logger "ACPI action undefined: $2"
    #             ;;
    #     esac
    #     ;;
    # battery)
    #     case "$2" in
    #         BAT0)
    #             case "$4" in
    #                 00000000)
    #                     logger 'Battery online'
    #                     ;;
    #                 00000001)
    #                     logger 'Battery offline'
    #                     ;;
    #             esac
    #             ;;
    #         CPU0)
    #             ;;
    #         *)  logger "ACPI action undefined: $2" ;;
    #     esac
    #     ;;
    # button/lid)
    #     case "$3" in
    #         close)
    #             logger 'LID closed'
    #             ;;
    #         open)
    #             logger 'LID opened'
    #             ;;
    #         *)
    #             logger "ACPI action undefined: $3"
    #             ;;
    # esac
    # ;;
    button/volumedown)
        case "$2" in
            VOLDN)
                fxply 'wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-'
                fxply 'notify-send "VolD" -r 30 --icon=audio-volume-low -t 1'
                ;;
        esac
        ;;
    button/volumeup)
        case "$2" in
            VOLUP)
                fxply 'wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+'
                fxply 'notify-send "VolU" -r 30 --icon=audio-volume-high -t 1'                
                ;;
        esac
        ;;
    button/mute)
        case "$2" in
            MUTE)
                fxply 'wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle'
                fxply 'notify-send "Mute" -r 30 --icon=audio-volume-muted -t 1'
                ;;
        esac
        ;;
    cd/prev)
        case "$2" in
            CDPREV)
                fxply 'playerctl previous'
	        fxply 'notify-send "Prev" -r 30 --icon=media-skip-backward -t 1'
                ;;
        esac
        ;;
    cd/play)
        case "$2" in
            CDPLAY)
                fxply 'playerctl play-pause'
                fxply 'notify-send "Play" -r 30 --icon=media-playback-start -t 1'
                ;;
        esac
        ;;
    cd/pause)
        case "$2" in
            CDPAUSE)
                fxply 'playerctl pause'
                fxply 'notify-send "Play" -r 30 --icon=media-playback-start -t 1'
                ;;
        esac
        ;;
    cd/play2)
        case "$2" in
            CDPLAY2)
                fxply 'playerctl play'
                fxply 'notify-send "Play" -r 30 --icon=media-playback-start -t 1'
                ;;
        esac
        ;;
    cd/next)
        case "$2" in
            CDNEXT)
                fxply 'playerctl next'
	            fxply 'notify-send "Next" -r 30 --icon=media-skip-forward -t 1'
                ;;
        esac
        ;; 
    # *)
    #     logger "ACPI group/action undefined: $1 / $2"
    #     ;;
esac

# vim:set ts=4 sw=4 ft=sh et: