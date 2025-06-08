# raspberry-pi-guitar
Turn your raspberry pi 4 into an amp&amp;cab with effects, using nam and a bunch of open source plugins.

## whats this
A hella long bash script that will turn your raspberry pi 4 into a guitar amp and a cabinet, with mod-ui to build your pedal board, and mod-host to let you chain together open source .lv2 plugins.

Highlights

- neural amp modeler
- impulse loader
- mod-ui
- mod-host
  
## prerequisits
- raspberry pi 4
- usb sound card that can record (e.g. Apogee jam, ugreen, etc)
- usb sound card that can play sound
- or a usb-c cable - this will make your pi appear as a sound card, e.g. on a mac

## setup
- flash a pi using the raspberry pi imager, call it `pedal`
- create a user for it, e.g. `nam`
- ensure you are able to ssh to the pi
- configure wifi for your pi
- download and run `pedal.sh`
- reboot it
- visit http://pedal.local or http://pedal.lan
