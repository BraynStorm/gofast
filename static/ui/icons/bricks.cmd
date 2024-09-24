@echo off
ffmpeg -framerate 5 -i bricks-%%d.png -plays 0 bricks.apng