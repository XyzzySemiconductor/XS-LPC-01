### HDMI debug

I feel all fpga project should have an HDMI connector dirctly wired to the fpga. It uses 4 differential signals, but gives unprecidented visibily into the device, that persists. At any time in the future hook up an HDMI montitor to the chip and you can see the debug screen (created during design debug). No software, not setup, no nothing, just an HDMI cable and monitor.

Creating the HDMI output sync, encoding etc is tiny. Adding a 32Mbyte psram SPI8 interface allows recording data, and basic logic allows pan zoom of the data.

I typicallyi set this up as 3Mhz recording for 1.3sec of 5 analog and 8 digital signals.

Live test overlays are used to display the digital values of critidal signals. 

Multiple 'scopes' have been built including slow scroll trasient captuting flwo, as well as the high res signals at full detail.

always, always, always. Except if you don't have space or IO :)
