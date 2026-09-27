# bench_native.py — "Pi running MNIST natively" timing, same net as the chip.
#
# Times the EXACT 2-layer chain the coprocessor implements (conv2d -> reduce
# -> pad28 -> conv2d) in pure Python, for each of the 5 batch-test images.
# Run it on any machine (x86 or Raspberry Pi) for a native-CPU baseline:
#
#     python3 bench_native.py            # 5 images, 3 timed runs each
#     python3 bench_native.py --runs 10
#
# Coprocessor-side numbers (measured in sim, /tmp/batch_run.log):
#   68.4 ms/image on an x86 host bit-banging SPI at 25 MHz sclk,
#   including all 11,757 SPI commands per layer. Engine compute itself:
#   ~0.2 ms per layer (AREA_TIMING_130NM.md).
#
# Stdlib only — no numpy.

import sys, time, statistics

sys.path.insert(0, ".")
sys.path.insert(0, "..")
import conv_ref
import quadbit_digits as QD

def one_image(frame1):
    """Full 2-layer chain, exactly as the host does it for the coprocessor."""
    out1   = conv_ref.conv2d(frame1, conv_ref.w1)
    frame2 = conv_ref.pad28(conv_ref.reduce(out1))
    out2   = conv_ref.conv2d(frame2, conv_ref.w2)
    return out1, out2

def main():
    runs = 3
    if "--runs" in sys.argv:
        runs = int(sys.argv[sys.argv.index("--runs") + 1])

    names = ["digit(MNIST)", "vertical bar", "diagonal", "ring", "noise"]
    imgs = list(zip(names, QD.make_images()))
    print(f"native-CPU baseline: {len(imgs)} images, {runs} timed runs each "
          f"(28x28 in, 3x3 x16 filters, 2 layers, pure Python)")
    print(f"python {sys.version.split()[0]} on {sys.platform}\n")

    per_image = []
    for name, frame1 in imgs:
        one_image(frame1)  # warmup (also JIT-free; CPython has none)
        times = []
        for _ in range(runs):
            t0 = time.perf_counter()
            one_image(frame1)
            times.append((time.perf_counter() - t0) * 1e3)  # ms
        med = statistics.median(times)
        per_image.append(med)
        print(f"  {name:14s} median {med:9.2f} ms   (min {min(times):.2f}, "
              f"max {max(times):.2f})")

    print(f"\n  per-image median (all): {statistics.median(per_image):.2f} ms")
    print(f"\nCoprocessor comparison (from sim, same net, 25 MHz sclk):")
    print(f"  x86 host, Python bit-banged SPI :  68.4 ms/image (measured)")
    print(f"  engine compute only             : ~0.4 ms/image  (2 x ~0.2 ms)")
    print(f"  SPI clock floor, 72,922 bytes   :  23.3 ms @25 MHz, 11.7 ms @50 MHz")
    print(f"  NOTE: protocol = 11,757 CS transactions/layer; on a real Pi via")
    print(f"  spidev each xfer costs ~10-50 us -> ~0.5-1.2 s/image. The per-")
    print(f"  command CS protocol, not the sclk rate, is the binding cost.")

if __name__ == "__main__":
    main()
