.POSIX:

# Set as appropriate for your installation; for example you may want:
# $ make install PREFIX="$HOME"
PREFIX = /usr/local

default:
	@echo "supported targets: install"

install:
	cp -R mpd_proto $(PREFIX)/lib/tcl/
	cp mprand tkmprand $(PREFIX)/bin/
