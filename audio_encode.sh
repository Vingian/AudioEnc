#!/bin/bash

encoded_directory='encoded'
audio_files=('*.wav' '*.m4a' '*.aac' '*.mp3' '*.ogg' '*.opus')
samples_options=('48000' '^44100' '32000' '22050')
bitrate_options=('320' '256' '^192' '128' '96' '64')
bitrate_quality_mp3=('0' '1' '2' '5' '7' '9')
bitrate_quality_ogg=('9' '8' '6' '4' '2' '0')
format_options=('^AAC' 'HE-AAC' 'MP3' 'OGG')
format_extensions=('m4a' 'm4a' 'mp3' 'ogg')
threads=5
status_pipe=$(mktemp -ut 'encoding-XXXX')

C_RED='\033[0;91m'
C_GREEN='\033[0;92m'
C_BLUE='\033[0;94m'
C_YELLOW='\033[0;93m'
NO_C='\033[0m'

bitrate_to_quality() {
  local bitrate="$1"
  shift
  local quality=("$@")
  for i in "${!bitrate_options[@]}"; do
    [ "${bitrate_options[$i]//^}" == "$bitrate" ] && break
  done
  echo ${quality[$i]}
}

extension_from_format() {
  for i in "${!format_options[@]}"; do
    [ "${format_options[$i]//^}" == "$1" ] && break
  done
  echo ${format_extensions[$i]}
}

limit_jobs() {
  while [ "$(jobs -p | wc -w)" -ge "$1" ]; do wait -n; done
}

to_variables() {
  read -r _x
  if [ -n "$_x" ]; then
    eval "local _g=($_x)"
    if [ "${#_g[@]}" -ge "$#" ]; then
      for _i in $(seq 1 $#); do
        eval "${!_i}=${_g[_i-1]@Q}"
      done
      return 0
    fi
  fi
  return 1
}

encoding_status() {
  if to_variables p t <<< ${*@Q}; then
    trap "rm -f '$p'" INT QUIT TERM EXIT

    exec 2> /dev/null

    if [ ! -p "$p" ]; then
      mkfifo $p
    fi

    local c=0
    while [ "$c" -lt "$t" ]; do
      ((c++))
      if read l < $p; then
        if [ "$l" == 'finished' ]; then
          break
        else
          echo -e "[${C_BLUE}$c/$t${NO_C}] $l"
        fi
      else
        break
      fi
    done
  fi
}

encode_audio_file() {
  if to_variables s b f g m p <<< ${*@Q}; then
    local mm="${m%.*}"
    local x="${m##*.}"
    local xx=$(extension_from_format "$f")
    local nm="$encoded_directory/$mm.$xx"
    local meta_ffmpeg=""
    local meta_fdkaac=""
    if [ "$g" == "TRUE" ]; then
      local ma="${mm%% - *}"
      local mn="${mm#* - }"
      if [ "$ma" == "$mn" ]; then
        meta_ffmpeg="-metadata title=${mn@Q}"
        meta_fdkaac="--title ${mn@Q}"
      else
        meta_ffmpeg="-metadata title=${mn@Q} -metadata artist=${ma@Q}"
        meta_fdkaac="--title ${mn@Q} --artist ${ma@Q}"
      fi
    fi
    if [ ! -f "$nm" ]; then
      local orig_nocasematch=$(shopt -p nocasematch; true)
      shopt -s nocasematch
      case $f in
        AAC)
          eval "ffmpeg -hide_banner -loglevel panic -i ${m@Q} -f wav -c:a pcm_s16le -ar '$s' -map_metadata -1 - | fdkaac -S -b '$b' $meta_fdkaac - -o ${nm@Q}"
          ;;
        HE-AAC)
          if [ "$b" -gt '128' ]; then
            b='128'
          fi
          eval "ffmpeg -hide_banner -loglevel panic -i ${m@Q} -f wav -c:a pcm_s16le -ar '$s' -map_metadata -1 - | fdkaac -S -p 5 -b '$b' $meta_fdkaac - -o ${nm@Q}"
          ;;
        MP3)
          local q=$(bitrate_to_quality "$b" "${bitrate_quality_mp3[@]}")
          eval "ffmpeg -hide_banner -loglevel panic -i ${m@Q} -f mp3 -c:a libmp3lame -q:a '$q' -ac 2 -ar '$s' -map_metadata -1 $meta_ffmpeg ${nm@Q}"
          ;;
        OGG)
          local q=$(bitrate_to_quality "$b" "${bitrate_quality_ogg[@]}")
          eval "ffmpeg -hide_banner -loglevel panic -i ${m@Q} -f ogg -c:a libvorbis -q:a '$q' -ar '$s' -map_metadata -1 $meta_ffmpeg ${nm@Q}"
          ;;
      esac
      $orig_nocasematch
      [ -p "$p" ] && echo -e "(${C_YELLOW}$x->$xx${NO_C}) ${C_BLUE}${mm:0:50}...${NO_C}" > "$p"
    else
      [ -p "$p" ] && echo -e "(${C_YELLOW}$x->$xx${NO_C}) ${C_YELLOW}${mm:0:50}...${NO_C}" > "$p"
    fi
  fi
}

for_each_audio_file() {
  to_variables p t x <<< ${*@Q}
  [ -n "$x" ] && eval "encoding_status '$p' '$t' &"
  local c=$(
    local c=0
    local orig_nullglob=$(shopt -p nullglob; true)
    local orig_nocaseglob=$(shopt -p nocaseglob; true)
    shopt -s nullglob
    shopt -s nocaseglob
    for m in ${audio_files[@]}; do
      ((c++))
      [ -n "$x" ] && eval "$x ${m@Q} '$p' &"
    done
    $orig_nocaseglob
    $orig_nullglob
    [ -n "$x" ] && wait
    echo $c
  )
  [ -n "$x" ] && [ "$c" -lt "$t" ] && echo 'finished' > "$p"
  return $c
}

encode() {
  IFS=\| read s b f g <<< "$(yad --center --fixed --title ' ' --form --align left --field 'Samples':CB "$(IFS=!; echo "${samples_options[*]}")" --field 'Bitrate':CB "$(IFS=!; echo "${bitrate_options[*]}")" --field 'Format':CB "$(IFS=!; echo "${format_options[*]}")" --field '         Create Metadata':CHK 'FALSE')"

  if [ -n "$s" -a -n "$b" -a -n "$f" -a -n "$g" ]; then
    pushd "$1" &> /dev/null
    for_each_audio_file
    local t=$?
    if [ "$t" -gt '0' ]; then
      mkdir -p $encoded_directory
      echo -e "${C_GREEN}Encoding to $f ${b}kb/s ${s}Hz...${NO_C}"
      for_each_audio_file "$status_pipe" "$t" "limit_jobs '$threads'; encode_audio_file '$s' '$b' '$f' '$g'"
      echo -e "${C_GREEN}Encoded $? files!${NO_C}"
    else
      echo -e "${C_RED}No audio files found...${NO_C}"
    fi
    popd &> /dev/null
    return 0
  fi

  return 1
}

dont_wait=0
if [ -z "$(type -p yad)" ]; then
  echo -e "${C_RED}YAD not found...${NO_C}"
elif [ -z "$(type -p ffmpeg)" ]; then
  echo -e "${C_RED}FFMPEG not found...${NO_C}"
elif [ -z "$(type -p fdkaac)" ]; then
  echo -e "${C_RED}FDKAAC not found...${NO_C}"
else
  if [ -n "$1" ]; then
    if [ -d "$1" ]; then
      directory=$1
    else
      directory=$(dirname "$1")
    fi
  else
    directory=$(dirname "$0")
  fi

  encode "$directory"
  dont_wait=$?
fi

if [ ! "$dont_wait" == '1' ]; then
  echo -e "${C_YELLOW}Press any key to exit...${NO_C}"
  read -rsn 1
fi
