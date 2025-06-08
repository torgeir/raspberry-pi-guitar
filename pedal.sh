#!/usr/bin/env bash
set -eo pipefail

# -----------------------
# Raspberry PI guitar rig
# -----------------------

# functions to log statements in color
g="\033[32m"
r="\033[31m"
o="\033[33m"
w="\033[37m"
c="\033[0m"
function log() {
  echo -e "${g}$1$c"
}
function log_warn() {
  echo -e "${r}$1$c"
}
function log_os() {
  echo -e "${w}os: ${o}$1$c"
}

sound_cards() {
  cat /proc/asound/cards \
    | awk -F'[][]' '{print $2}' \
    | awk 'NF'
}

update_os() {
  log_os "running apt update.."
  sudo apt update
  log_os "running apt upgrade.."
  sudo apt upgrade
}

ensure_deps() {
  log_os "install alsa and deps"
  sudo apt install -y libasound2-dev g++ cmake alsa-tools alsa-utils 
  
  log_os "lv2 plugins$c enough to build them"
  sudo apt install -y build-essential git lv2-dev pkg-config libsndfile1-dev libfftw3-dev libcairo2-dev libx11-dev 
  
  log_os "install mod-host deps"
  sudo apt install -y libreadline-dev liblilv-dev lilv-utils libjack-jackd2-dev 
  log_os "install mod-ui deps"
  sudo apt install -y libjpeg-dev zlib1g-dev python3-setuptools python3-dev libfreetype6-dev authbind
  
  log_os "install useful apps"
  sudo apt install -y wget tmux git vim netcat-openbsd exa htop fzf
  
  log_os "install ImpulseLoaderStereo's xxd$c nescessary for building it"
  # https://github.com/brummer10/ImpulseLoaderStereo.lv2/issues/4
  sudo apt install xxd
  
  log_os "install lv2ls$c to list installed lv2 plugins"
  sudo apt install -y lilv-utils
  
  # lv2 plugin host https://github.com/drobilla/jalv/
  #sudo apt install -y jalv

  log_os "guitarix plugins lv2"
  sudo apt install guitarix-lv2

  # git clone https://github.com/x42/darc.lv2.git
  # sudo apt-get install libcairo2-dev libpango1.0-dev libglu1-mesa-dev libgl1-mesa-dev

  log_os "jack2 + jack-tools"
  sudo apt install -y --no-install-recommends jackd2 jack-tools


  log_os "disabling and stopping all unnescessary processing to prevent xruns.."
  sudo dphys-swapfile swapoff
  sudo systemctl disable dphys-swapfile cron bluetooth hciuart triggerhappy prometheus-node-exporter ModemManager nvmf-autoconnect openipmi smartmontools
  sudo systemctl stop    dphys-swapfile cron bluetooth hciuart triggerhappy prometheus-node-exporter ModemManager nvmf-autoconnect openipmi smartmontools
}

realtime_jack() {
  log "configuring realtime jack"
  DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NONINTERACTIVE_SEEN=true \
    sudo dpkg-reconfigure --frontend=noninteractive -p high jackd2
  echo
  log_warn "you should log out and log in again after this (adjusted rtprio), or just reboot"
  echo
}

deps_cleanup() {
  log "deps cleanup:$c remove no longer needed deps"
  sudo apt autoremove
}

create_folders() {
  log "creating ~/.bin:$c scripts to run everything will be put here"
  mkdir -p ~/bin

  mkdir -p ~/plugs
  log "creating ~/.plugs:$c plugins will be downloaded here"

  mkdir -p ~/.lv2
  log "creating ~/.lv2:$c plugins will be installed here"

  log "$(cat <<EOF
creating ~/mod-user-files:$c the folders where you will put models and IRs go $g
# ~/mod-user-files
#  |- "Aida DSP Models"
#  |- "Audio Loops"
#  |- "Audio Recordings"
#  |- "Audio Samples"
#  |- "Audio Tracks"
#  |- "Hydrogen Drumkits"
#  |- "MIDI Clips"
#  |- "MIDI Songs"
#  |- "NAM Models"              $c <-- put models here $g
#  |- "Reverb IRs"
#  |- "SF2 Instruments"
#  |- "SFZ Instruments"
#  |- "Speaker Cabinets IRs"    $c <-- put IRs here $c
EOF
)"
  # mod-ui expects these folders
  mkdir -p mod-user-files/Aida\ DSP\ Models
  mkdir -p mod-user-files/Audio\ Loops
  mkdir -p mod-user-files/Audio\ Recordings
  mkdir -p mod-user-files/Audio\ Samples
  mkdir -p mod-user-files/Audio\ Tracks
  mkdir -p mod-user-files/Hydrogen\ Drumkits
  mkdir -p mod-user-files/MIDI\ Clips
  mkdir -p mod-user-files/MIDI\ Songs
  mkdir -p mod-user-files/NAM\ Models
  mkdir -p mod-user-files/Reverb\ IRs
  mkdir -p mod-user-files/SF2\ Instruments
  mkdir -p mod-user-files/SFZ\ Instruments
  mkdir -p mod-user-files/Speaker\ Cabinets\ IRs
}

install_mod_host() {
  if [ -d mod-host ]; then
    log "mod-host:$c already installed"
    return
  fi

  log "mod-host:$c downloading"
  git clone --recurse-submodules -j4 https://github.com/mod-audio/mod-host.git
  pushd mod-host
    log "mod-host:$c compiling"
    make
    log "mod-host:$c installing"
    sudo make install
  popd
}

install_mod_ui() {
  if [ -d mod-ui ]; then
    log "mod-ui:$c already installed"
    return
  fi

  log "mod-ui:$c downloading"
  git clone https://github.com/moddevices/mod-ui
  pushd mod-ui

  log "mod-ui:$c creating venv"
  python -m venv modui-env

  log "mod-ui:$c activating venv"
  source modui-env/bin/activate

  log "mod-ui:$c installing dependencies in venv"
  pip install -r requirements.txt

  log "mod-ui:$c compiling"
  make -C utils

  log "mod-ui:$c apply crazy python3.11 tornado hack, mod-ui seems to expect python3.10"
  sed -i -e 's/collections.MutableMapping/collections.abc.MutableMapping/' \
    modui-env/lib/python3.11/site-packages/tornado/httputil.py
  popd
}

install_mod_plugins() {
  if [ ! -d plugs/mod-lv2-data ]; then
    log "mod plugins:$c downloading"
    git clone https://github.com/mod-audio/mod-lv2-data.git plugs/mod-lv2-data
  else
    log "mod plugins:$c already downloaded"
  fi
  # needs apt install guitarix-lv2
  if [ ! -d ~/.lv2/gx_amp.lv2 ]; then
    log "mod plugins:$c copy already compiled plugins into place"
    cp -r plugs/mod-lv2-data/plugins/gx_*.lv2 ~/.lv2/
    cp -r plugs/mod-lv2-data/plugins-fixed/gx_*.lv2 ~/.lv2/
  else
    log "mod plugins:$c plugins already installed"
  fi
}

install_impulse_loader() {
  if [ ! -d plugs/ImpulseLoader.lv2 ]; then
    log "impulse loader:$c downloading"
    git clone --recurse-submodules -j4 https://github.com/brummer10/ImpulseLoader.lv2.git plugs/ImpulseLoader.lv2
  else
    log "impulse loader:$c already downloaded"
  fi
  if [ ! -d ~/.lv2/ImpulseLoader.lv2 ]; then
    pushd plugs/ImpulseLoader.lv2
      log "impulse loader:$c compiling"
      make

      log "impulse loader:$c installing"
      mv bin/ImpulseLoader.lv2 ~/.lv2/

      log "impulse loader:$c make mod-ui show cabsims (i.e. wav files) from 'Speaker Cabinets IRs' in the ImpulseLoader plugin"
      sed -i '/^ *mod:fileTypes/s/"wav,audio"/"wav,audio,cabsim"/' ~/.lv2/ImpulseLoader.lv2/ImpulseLoader.ttl
    popd
  else
    log "impulse loader:$c already installed"
  fi
}

install_ratatouille() {
  if [ ! -d plugs/Ratatouille.lv2 ]; then
    log "ratatouille:$c downloading"
    git clone --recurse-submodules -j4 https://github.com/brummer10/Ratatouille.lv2 plugs/Ratatouille.lv2
  else
    log "ratatouille:$c already downloaded"
  fi
  if [ ! -d ~/.lv2/Ratatouille.lv2 ]; then
    pushd plugs/Ratatouille.lv2
      log "ratatouille:$c compiling"
      make
      log "ratatouille:$c installing"
      mv bin/Ratatouille.lv2 ~/.lv2/
    popd
  else
    log "ratatouille:$c already installed"
  fi
}

install_neural_amp_modeler() {
  if [ ! -d plugs/neural-amp-modeler-lv2 ]; then
    log "neural amp modeler:$c downloading"
    git clone --recurse-submodules -j4 https://github.com/mikeoliphant/neural-amp-modeler-lv2 plugs/neural-amp-modeler-lv2
  else
    log "neural amp modeler:$c already downloaded"
  fi
  if [ ! -d ~/.lv2/neural_amp_modeler.lv2 ]; then
    pushd plugs/neural-amp-modeler-lv2/build
      log "neural amp modeler:$c compiling"
      cmake .. -DCMAKE_BUILD_TYPE="Release" -DWAVENET_FRAMES=$(cat .preferred-period-frames)
      make -j4

      log "neural amp modeler:$c installing"
      mv neural_amp_modeler.lv2 ~/.lv2/
    popd
  else
    log "neural amp modeler:$c already installed"
  fi
}

install_neural_rack() {
  if [ ! -d plugs/NeuralRack ]; then
    log "neural rack:$c downloading"
    git clone --recurse-submodules -j4 https://github.com/brummer10/NeuralRack.git plugs/NeuralRack
  else
    log "neural rack:$c already downloaded"
  fi
  if [ ! -d ~/.lv2/Neuralrack.lv2 ]; then # sic
    pushd plugs/NeuralRack
      log "neural rack:$c submodules"
      git submodule update --init --recursive

      log "neural rack:$c compiling"
      make lv2

      log "neural rack:$c installing"
      make install
    popd
  else
    log "neural rack:$c already installed"
  fi
}

install_dragonfly() {
  if [ ! -d plugs/dragonfly-reverb ]; then
    log "dragonfly:$c downloading"
    git clone --recurse-submodules -j4 https://github.com/pedalboard/dragonfly-reverb.git plugs/dragonfly-reverb
  else
    log "dragonfly:$c already downloaded"
  fi
  if [ ! -d ~/.lv2/DragonflyHallReverb.lv2 ]; then
    pushd plugs/dragonfly-reverb
      log "dragonfly:$c compiling"
      make
      log "dragonfly:$c installing"
      mv bin/*.lv2 ~/.lv2/
    popd
  else
    log "dragonfly:$c already installed"
  fi
}

install_floaty() {
  if [ ! -d ~/.lv2/floaty.lv2 ]; then
    # https://patchstorage.com/floaty/
    pushd plugs
      log "install floaty:$c downloading"
      wget https://patchstorage.com/wp-content/uploads/2023/04/floaty-643379f86ffb2.lv2.tar.gz
      log "install floaty:$c unpacking"
      tar xvfz floaty-643379f86ffb2.lv2.tar.gz -C ~/.lv2/
    popd
  fi
}

install_avocado() {
  if [ ! -d ~/.lv2/avocado.lv2 ]; then
    # https://patchstorage.com/avocado/
    pushd plugs
      log "avocado:$c downloading"
      wget https://patchstorage.com/wp-content/uploads/2023/04/avocado-643379569b045.lv2.tar.gz
      log "avocado:$c unpacking"
      tar xvfz avocado-643379569b045.lv2.tar.gz -C ~/.lv2/
    popd
  else
    log "avocado:$c already installed"
  fi
}

install_noisegate() {
  if [ ! -d plugs/noisegate ]; then
    log "install noisegate:$c downloading"
    git clone https://github.com/VeJa-Plugins/Noise-Gate.git plugs/noisegate
  else
    log "install noisegate:$c already installed"
  fi
  if [ ! -d ~/.lv2/noisegate.lv2 ]; then
    pushd plugs/noisegate
      log "noisegate:$c compiling"
      make clean
      make
      log "noisegate:$c installing"
      mv noisegate.lv2 ~/.lv2/
    popd
  else
    log "noisegate:$c already installed"
  fi
}

preset_model() {
  if [ ! -f mod-user-files/Speaker\ Cabinets\ IRs/mesa-os-57.wav ]; then
    log "neural_amp_modeler:$c fetching m100-cln.nam amp model"
    wget https://github.com/torgeir/raspberry-pi-guitar/raw/refs/heads/main/m100-cln.nam \
      -O mod-user-files/NAM\ Models/m100-cln.nam
  else
    log "neural_amp_modeler:$c already got m100-cln.nam amp model"
  fi

  log "neural_amp_modeler:$c creating preset model"
  cat <<EOF > ~/.lv2/neural_amp_modeler.lv2/manifest.ttl
@prefix atom: <http://lv2plug.in/ns/ext/atom#> .
@prefix lv2: <http://lv2plug.in/ns/lv2core#> .
@prefix pset: <http://lv2plug.in/ns/ext/presets#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix state: <http://lv2plug.in/ns/ext/state#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

<http://github.com/mikeoliphant/neural-amp-modeler-lv2>
  a lv2:Plugin;
  lv2:binary <neural_amp_modeler.so>;
  rdfs:seeAlso <neural_amp_modeler.ttl>.

<model>
  a pset:Preset ;
  rdfs:label "model" ;
  lv2:appliesTo <http://github.com/mikeoliphant/neural-amp-modeler-lv2> ;
  state:state [ <http://github.com/mikeoliphant/neural-amp-modeler-lv2#model> "/home/$user/mod-user-files/NAM Models/m100-cln.nam" ] .
EOF
}

preset_ir() {
  if [ ! -f mod-user-files/Speaker\ Cabinets\ IRs/mesa-os-57.wav ]; then
    log "ImpulseLoader:$c fetching mesa-os-57.wav cabinet ir"
    wget https://github.com/torgeir/raspberry-pi-guitar/raw/refs/heads/main/mesa-os-57.wav \
      -O mod-user-files/Speaker\ Cabinets\ IRs/mesa-os-57.wav
  else
    log "ImpulseLoader:$c already got mesa-os-57.wav cabinet ir"
  fi

  log "ImpulseLoader:$c creating preset ir"
  cat <<EOF > ~/.lv2/ImpulseLoader.lv2/manifest.ttl
@prefix atom: <http://lv2plug.in/ns/ext/atom#> .
@prefix lv2: <http://lv2plug.in/ns/lv2core#> .
@prefix pset: <http://lv2plug.in/ns/ext/presets#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix state: <http://lv2plug.in/ns/ext/state#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

<urn:brummer:ImpulseLoader>
  a lv2:Plugin ;
  lv2:binary <ImpulseLoader.so> ;
  rdfs:seeAlso <ImpulseLoader.ttl> .

<urn:brummer:ImpulseLoader#ir>
  a pset:Preset ;
  lv2:appliesTo <urn:brummer:ImpulseLoader> ;
  rdfs:label "ir" ;
  lv2:port [
    lv2:symbol "Bypass" ;
    pset:value 0.0
  ] , [
    lv2:symbol "DRY_WET" ;
    pset:value 100.0
  ] , [
    lv2:symbol "INPUT" ;
    pset:value 0.0
  ] ;
  state:state [
    atom:Path "/home/$user/mod-user-files/Speaker Cabinets IRs/mesa-os-57.wav"
  ] .
EOF
}

create_jack() {
  log "create ~/bin/launch-jack:$c that will launch jackd, to be able to route audio between plugins using mod-ui, through mod-host"
  cat <<EOF > ~/bin/launch-jack
#!/usr/bin/env bash

test_is_usbgadget() {
   grep -q "configured" /sys/class/udc/*/state 2>/dev/null
}

hw_in=\$(cat ~/.preferred-sound-card-in)
if test_is_usbgadget; then
  hw_out=UAC2Gadget
else
  hw_out=\$(cat ~/.preferred-sound-card-out)
fi
echo "Staring jack with:"
echo "- input device \$hw_in"
echo "- output device \$hw_out"
cat <<EOF_INNER > ~/.asoundrc
pcm.audiorig {
    type asym
    playback.pcm "hw:\$hw_out,0"
    capture.pcm "hw:\$hw_in,0"
}
pcm.!default {
    type plug
    slave.pcm "audiorig"
}
EOF_INNER

JACK_NO_AUDIO_RESERVATION=1 \
  jackd -v -P95 -R -s -S -t1000 \
  -d alsa -d audiorig -i 1 -o 2 -p$(cat ~/.preferred-period-frames) -n3 -r48000
EOF
  chmod u+x ~/bin/launch-jack
}

create_mod_host() {
  log "create ~/bin/launch-mod-host:$c that will launch mod-host, to be able to run plugins without a daw"
  cat <<EOF > ~/bin/launch-mod-host
#!/usr/bin/env bash
mod-host -n -p 5555 -f 5556
EOF
  chmod u+x ~/bin/launch-mod-host
}

create_mod_ui() {
  log "create ~/bin/launch-mod-ui:$c that will launch mod-ui, to you can build your pedalboard in the browser"
  cat <<EOF > ~/bin/launch-mod-ui
#!/usr/bin/env bash
cd /home/$user/mod-ui
source modui-env/bin/activate
# https://patchstorage.com/docs/api/beta/
#  PATCHSTORAGE_PLATFORM_ID=8046 is LV2 Plugins
#  PATCHSTORAGE_TARGET_ID=8280 is rpi-aarch64
MOD_SOUNDCARD=\$(cat ~/.preferred-sound-card-in) \
  MOD_DEV_ENVIRONMENT=0 \
  MOD_USER_FILES_DIR=/home/$user/mod-user-files \
  PATCHSTORAGE_API_URL=https://patchstorage.com/api/beta/patches \
  PATCHSTORAGE_PLATFORM_ID=8046 \
  PATCHSTORAGE_TARGET_ID=8280 \
  python ./server.py
EOF
  chmod u+x ~/bin/launch-mod-ui
}

# https://torgeir.dev/2023/08/pwm-fan-on-raspberry-pi-4/
setup_fan() {
  if [ ! -d ~/fan ]; then
    log "fan:$c creating ~/fan"
    mkdir -p ~/fan
    cd fan

    log "fan:$c creating venv"
    python -m venv fan-env

    log "fan:$c activating venv"
    source fan-env/bin/activate

    log "fan:$c intalling RPi:GPIO"
    pip install RPi.GPIO

    cat <<EOF > fan.py
import time
import RPi.GPIO as gpio

gpio.setmode(gpio.BCM)
gpio.setup(14, gpio.OUT)

pwm = gpio.PWM(14, 50)
pwm.start(100)

while True:
  time.sleep(1)
  pwm.ChangeDutyCycle(25)

def signal_handler(sig, frame):
  pwm.stop()
  gpio.cleanup()
  raise KeyboardInterrupt

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)
EOF
  else
    log "fan:$c already installed"
  fi

  log "fan:$c creating ~/bin/launch-fan "
  cat <<EOF > ~/bin/launch-fan 
#!/usr/bin/env bash
cd /home/$user/fan
source fan-env/bin/activate
python fan.py
  EOF

  sudo tee /etc/systemd/system/fan.service > /dev/null <<EOF 
[Unit]
Description=pwm-fancontrol

[Service]
User=$user
ExecStart=/home/$user/bin/launch-fan

[Install]
WantedBy=multi-user.target
EOF

  log "fan:$c making it runnable"
  chmod u+x ~/bin/launch-fan
}

create_systemd_service() {
  log "create /etc/systemd/journald.conf:$c to configure less logging"
sudo tee /etc/systemd/journald.conf > /dev/null << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
RuntimeMaxFileSize=8M
#MaxLevelStore=warning
#MaxLevelSyslog=warning
#MaxLevelKMsg=warning
#MaxLevelConsole=warning
#ForwardToSyslog=no
#ForwardToKMsg=no
#ForwardToConsole=no
#ForwardToWall=no
EOF

  log "create ~/bin/pedal-service:$c that will tie the previous scripts together"
  cat <<EOF > ~/bin/pedal-service
#!/usr/bin/env bash
# sleep timeouts by experimentation
sleep 0 && /home/$user/bin/launch-fan &
sleep 0 && /home/$user/bin/launch-jack &
sleep 3 && /home/$user/bin/launch-mod-host &
sleep 4 && /home/$user/bin/launch-mod-ui &
wait
EOF
  log "create ~/bin/pedal-service:$c make it runnable"
  chmod u+x ~/bin/pedal-service

  log "run authbind:$c to allow mod-ui to start on port 80, so you can reach it without specifying the port"
  sudo touch /etc/authbind/byport/80
  sudo chown $user /etc/authbind/byport/80
  sudo chmod 755 /etc/authbind/byport/80
  sed -i "/MOD_DEVICE_WEBSERVER_PORT/s/8888/80/" ~/mod-ui/server.py

  # https://github.com/SolsticeFX/pi-stomp-bookworm/blob/aeff925037e3318b078fc1418ddd86ed88d37d25/setup/mod/mod-ui.service#L25
  log "create pedal.service:$c the system service that will run ~/bin/pedal-service on boot"
  sudo tee /etc/systemd/system/pedal.service &>/dev/null <<EOF
[Unit]
Description=Pedal Startup Service
After=network.target

[Service]
User=$user
LimitRTPRIO=95
LimitMEMLOCK=infinity 
ExecStart=/usr/bin/authbind --deep /home/$user/bin/pedal-service
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

usb_gadget_mode() {
  log "usb gadget:$c clean up previous setup"
  # Clean up any existing gadget
  sudo sh -c 'echo "" > /sys/kernel/config/usb_gadget/*/UDC' 2>/dev/null || true
  sudo rm -rf /sys/kernel/config/usb_gadget/* 2>/dev/null || true
  sudo modprobe -r g_ether g_serial g_mass_storage g_audio libcomposite 2>/dev/null || true

  log "usb gadget: create ~/bin/usb-gadget-audio:$c that will make the raspberry pi appear as a soundcard, e.g. when plugged into a mac with usb-c power port"
  sudo tee ~/bin/usb-gadget-audio > /dev/null <<EOF
#!/bin/bash
cd /sys/kernel/config/usb_gadget/
mkdir -p pi-audio
cd pi-audio

echo 0x1d6b > idVendor  # linux foundation
echo 0x0104 > idProduct # multifunction composite gadget
echo 0x0100 > bcdDevice # v1.0.0
echo 0x0200 > bcdUSB    # USB 2.0

mkdir -p strings/0x409
echo "fedcba9876543210" > strings/0x409/serialnumber
echo "Raspberry Pi" > strings/0x409/manufacturer
echo "Pi Audio Interface" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "Audio" > configs/c.1/strings/0x409/configuration

mkdir -p functions/uac2.usb0
echo 48000 > functions/uac2.usb0/c_srate
echo 48000 > functions/uac2.usb0/p_srate
echo 2 > functions/uac2.usb0/c_chmask
echo 2 > functions/uac2.usb0/p_chmask

ln -s functions/uac2.usb0 configs/c.1/
ls /sys/class/udc > UDC
EOF

  log "usb gadget:$c make the setup runnable"
  chmod u+x ~/bin/usb-gadget-audio

  log "create usb-gadget-audio.service:$c that will set up the pi as a usb gadget on boot"
  sudo tee /etc/systemd/system/usb-gadget-audio.service > /dev/null <<EOF
[Unit]
Description=USB Gadget Audio
After=network.target

[Service]
Type=oneshot
ExecStart=/home/$user/bin/usb-gadget-audio
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl enable usb-gadget-audio.service
  sudo systemctl start usb-gadget-audio.service
}

# Configures /boot/firmware/config.txt for USB audio gadget functionality,
# and removes the default audio output and adds USB gadget, performance, and bluetooth settings.
setup_config_txt() {
  log "setup /boot/firmware/config.txt:$c configuring boot settings for USB gadget audio"
  sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak
  sudo sed -i \
    -e '/dtparam=audio=on/d' \
    -e '/dtoverlay=dwc2/d' \
    -e '/force_turbo=1/d' \
    -e '/dtoverlay=disable-bt/d' \
    -e '$a dtoverlay=dwc2' \
    -e '$a force_turbo=1' \
    -e '$a dtoverlay=disable-bt' \
    /boot/firmware/config.txt

  log_warn "/boot/firmware/config.txt:$c - reboot required for changes to take effect"
}

# Configures boot parameters /boot/firmware/cmdline.txt to enable USB audio gadget mode,
# and sets options to dont pause usb devices, and force controller speed to limit interrupts
# to improve realtime audio.
# Adds these to the default:
#   modules-load=dwc2,g_audio usbcore.autosuspend=-1 dwc_otg.speed=1
setup_cmdline_txt() {
  sudo cp /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak
  sudo sed -i.bak \
    -e 's/modules-load=dwc2,g_audio//g' \
    -e 's/usbcore\.autosuspend=-1//g' \
    -e 's/dwc_otg\.speed=1//g' \
    -e 's/  */ /g' \
    -e 's/rootwait/rootwait modules-load=dwc2,g_audio usbcore.autosuspend=-1 dwc_otg.speed=1/' \
    /boot/firmware/cmdline.txt
}

# not nescessary with mod-ui, it does this
#create_connect() {
#  cat <<EOF > launch-connect
##!/usr/bin/env bash
#sleep 4
#jack_connect system:capture_1 effect_1:input
#jack_connect effect_1:output effect_2:in0
#jack_connect effect_2:out0 system:playback_2
#jack_lsp -c
#EOF
#  chmod u+x launch-connect
#}

log "$(cat <<EOF
${o}:: Raspberry PI neural amp modeller guitar rig ::
$r
This script will $g
- update and prepare the os
- install nescessary dependencies
- configure jackd for realtime audio
- download, compile and install a bunch of plugins
  - mod-host
  - mod-ui
  - nam
  - impulse loader
  - effects++
- create script to launch everything
- bundle everything into a service that starts on boot
- configure the pi as an usb gadget "soundcard"
EOF
)
"

user=$USER
cd

log "-$r need:$c sudo"
log "-$r run as:$c $user"
log "-$r install a bunch of things in:$c $PWD\n"
read -p "Press enter to proceed.."

if [ ! -f ~/.pedal.deps ]; then
  log_warn "Preparing OS. Remove the$c ~/.pedal.deps$r file to update or do it again.\n"
  update_os
  ensure_deps
  realtime_jack
  deps_cleanup
  setup_cmdline_txt
  setup_config_txt
  usb_gadget_mode
  touch ~/.pedal.deps
fi

log 'Jack number of period frames. 96 seems to work fine on a raspberry pi 4,
with low enough latency, without many pops and clicks (this also depends on
how many effects you run). You can raise this value to e.g. 128 or more if
you experience pops and clicks or look into tuning the os for less xruns. 

Read more: https://wiki.linuxaudio.org/wiki/list_of_jack_frame_period_settings_ideal_for_usb_interface'
log_warn "Choose number of jack period frames:"
echo -e "96\n128\n144\n192\n256\n512" \
  | fzf --height 10% --reverse \
  | tee ~/.preferred-period-frames

log "Found the following usb sound cards (cat /proc/asound/cards):"
cat /proc/asound/cards

log_warn "Choose preferred input sound card:"
echo -e "$(sound_cards)" \
  | fzf --height 10% --reverse \
  | tr -d ' ' \
  | tee ~/.preferred-sound-card-in

log_warn "Choose preferred output sound card (they can be the same):"
echo -e "$(sound_cards)" \
  | fzf --height 10% --reverse \
  | tr -d ' ' \
  | tee ~/.preferred-sound-card-out

create_folders
install_mod_host
install_mod_ui
install_mod_plugins

# amp+cab
install_impulse_loader
install_neural_amp_modeler
install_neural_rack
install_ratatouille

# plugins
install_noisegate
install_dragonfly
install_floaty
install_avocado

preset_model
preset_ir

setup_fan
create_jack
create_mod_host
create_mod_ui
create_systemd_service

log "reloading existing service definitions.."
sudo systemctl daemon-reload

log "killing jackd.."
sudo killall jackd >/dev/null 2>&1

log "starting/restarting pedal.service.."
sudo systemctl restart pedal.service

log "making pedal.service start on boot as well.."
sudo systemctl enable pedal.service

log "$(cat <<EOF

Done.
$oNow what?$c

$g  Reboot, if this is your first time running the script:
$c    sudo reboot
$g  Copy models, so mod-ui will show them in the ui, e.g. in Neural Amp Modeler:
$c    scp model.nam nam@pedal.lan:/home/$user/mod-user-files/NAM\ Models/
$g  Copy IRs, so mod-ui will show them in the ui, e.g. in ImpulseLoader:
$c    scp cab-ir.wav nam@pedal.lan:/home/$user/mod-user-files/Speaker\ Cabinet\ IRs/
$g  Stop service:
$c    sudo systemctl restart pedal.service
$g  Restart service:
$c    sudo systemctl restart pedal.service
$g  Show last logs:
$c    journalctl -u pedal.service -b0
$g  Tail logs:
$c    journalctl -u pedal.service -f
$g  Adjust overall volume:
$c     alsamixer
$g  Store set volume:
$c    sudo alsactl store
$g  It is restored on boot, or using:
$c    sudo alsactl restore
  
  Visit$c http://pedal.lan$g

  Enjoy!
EOF
)\n"
