# Measuring your room with REW

This guide takes you from a microphone to a Flatroom filter with [REW](https://www.roomeqwizard.com) (free, runs natively on Apple Silicon) and `filter-design/design_fir.py`.

You need a measurement microphone with its calibration file, such as a UMIK-1, or an XLR mic like the Sonarworks XREF 20 on your interface, plus a mic stand.

## 1. Before you start

- **Let REW play uncorrected.** Flatroom corrects everything that plays, REW's test sweep included. Once REW has opened your interface, tick it in Flatroom's **Uncorrected apps** menu; the menu then says *REW plays directly: ready to measure the room*. Flatroom recognises REW, so it never mistakes a measurement for a call. Quitting Flatroom works too.
- **Turn the volume down.** Uncorrected apps skip Flatroom's volume, so your interface's knob sets the sweep's level. Some interfaces have no software volume at all.
- Keep the room as you use it: furniture, curtains and doors as usual, with the speakers and your seat where they normally are.

## 2. Set up REW

1. **Preferences → Soundcard:** choose your interface for output and input, and set the sample rate to 48 kHz. Choose the input channel your mic is on.
2. **Preferences → Cal files:** load your mic's calibration file. If it comes with several angles, use the 90° file and point the mic straight up at the ceiling. That way the mic hears both speakers and every position the same way. Otherwise, use the 0° file and point the mic at the speaker you're measuring.
3. Put the mic at ear height at your listening position.

## 3. Measure

1. Click **Measure**. Use a 20 Hz to 20 kHz sweep with a 256k length, and choose the **left** output channel.
2. Click **Check levels** and raise the level until the sweep is clearly louder than the room noise, around 75 to 85 dB SPL at the seat. REW warns you if the input clips.
3. Start the measurement, then repeat it with the **right** output channel.
4. **Optional, recommended: measure more positions.** Move the mic 20 to 30 cm (left, right, forward, back, a little up) and measure both speakers each time. Five to nine positions around your head give a correction that holds up when you move, and Flatroom's design script averages them for you. Keep the mic orientation the same for every position.

Name the measurements as you go, such as `L-1`, `R-1`, `L-2`, `R-2`, and so on.

## 4. Export

For each measurement, use **File → Export → Measurement as text**. Export it without smoothing, or with 1/48 octave smoothing at most, because the script does its own smoothing. Put the files in one folder, for example:

```
measurements/L-1.txt  measurements/R-1.txt
measurements/L-2.txt  measurements/R-2.txt
…
```

## 5. Design the filter

```bash
cd filter-design
uv run python design_fir.py --left measurements/L-*.txt --right measurements/R-*.txt --name my-room
```

With a single position, `--measurement L-1.txt R-1.txt` does the same.

The script power-averages each speaker's positions (like REW's RMS average) and smooths them to 1/6 octave (`--smoothing`). It then sets 200 Hz to 2 kHz to 0 dB and inverts the curve. The filter appears in Flatroom immediately. Check `response.png` in the filter's folder: the bottom chart shows the measured response and the predicted response with the filter.

A starting point that sounds natural to most people:

```bash
uv run python design_fir.py --left measurements/L-*.txt --right measurements/R-*.txt \
    --phase linear --max-cut 9 --bass-db 3 --hf-from 500 --hf-amount 0.5 --boost-min-hz 30 \
    --name my-room-linear
```

- `--boost-min-hz`: don't boost below your speakers' low-frequency limit. Boosting there only costs headroom and excursion.
- `--hf-from 500 --hf-amount 0.5`: above 500 Hz, correct half of the trend and leave the fine detail alone. A single mic position can't measure that detail reliably anyway.
- `--bass-db 3`: a target with a little more bass than flat, which most rooms and listeners prefer.

## 6. Check the result

1. Pick the new filter in Flatroom's **Output profiles**.
2. Untick REW in **Uncorrected apps**, so it plays through the correction. The menu says *REW plays corrected*.
3. Measure again at the main position. The response should follow the predicted curve from `response.png`. With a linear-phase filter, REW reports a delay of about 350 ms. That delay is the filter's latency, and it's expected.

Start with the volume low whenever you load a new filter.
