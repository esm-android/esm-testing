# ESM Performance Test Results

Generated: Wed Jan  7 11:52:06 PM EST 2026

## Summary

| Metric | Baseline | ESM | Improvement | p-value | Effect Size |
|--------|----------|-----|-------------|---------|-------------|
| Latency - Single Tap (ms) | 0.03 (n=102) | 0.04 (n=112) | -63.1% | 0.0000* | large (d=-1.67) |
| Latency - Fast Swipe (ms) | 0.02 (n=29) | 0.04 (n=22) | -74.8% | 0.0000* | large (d=-2.00) |
| CPU - system_server (%) | 5.56 (n=5) | 4.00 (n=5) | +28.1% | 0.0583 | large (d=1.20) |
| CPU - Total (%) | 9.10 (n=5) | 8.76 (n=5) | +3.7% | 0.0835 | large (d=1.09) |
| Wakeups per second | 57.43 (n=5) | 65.98 (n=5) | -14.9% | 0.4251 | medium (d=-0.50) |
| Power - Idle Battery Drain (%) | 2.20 (n=5) | 1.20 (n=5) | +45.5% | 0.3573 | medium (d=0.58) |
| Power - Idle Wakeups/sec | 6319.64 (n=5) | 470.23 (n=5) | +92.6% | 0.0013* | large (d=2.03) |
| Power - Active Battery Drain (%) | 0.60 (n=5) | 0.20 (n=5) | +66.7% | 0.3711 | medium (d=0.57) |
| Power - Active Wakeups/sec | 1042.32 (n=5) | 210.54 (n=5) | +79.8% | 0.0000* | large (d=10.57) |

*p < 0.05 (statistically significant)

## Detailed Results

### Latency - Single Tap (ms)

**Baseline (epoll)**
- Mean: 0.03
- Std Dev: 0.01
- 95% CI: [0.02, 0.03]
- Range: [0.01, 0.10]
- n: 102

**ESM**
- Mean: 0.04
- Std Dev: 0.01
- 95% CI: [0.04, 0.04]
- Range: [0.02, 0.06]
- n: 112

**Statistical Analysis**
- Improvement: -63.1%
- t-statistic: -12.174
- p-value: 0.0000
- Cohen's d: -1.673 (large)
- Significant (p<0.05): Yes

### Latency - Fast Swipe (ms)

**Baseline (epoll)**
- Mean: 0.02
- Std Dev: 0.01
- 95% CI: [0.02, 0.03]
- Range: [0.01, 0.04]
- n: 29

**ESM**
- Mean: 0.04
- Std Dev: 0.01
- 95% CI: [0.04, 0.05]
- Range: [0.03, 0.07]
- n: 22

**Statistical Analysis**
- Improvement: -74.8%
- t-statistic: -6.493
- p-value: 0.0000
- Cohen's d: -2.003 (large)
- Significant (p<0.05): Yes

### CPU - system_server (%)

**Baseline (epoll)**
- Mean: 5.56
- Std Dev: 0.56
- 95% CI: [5.06, 6.06]
- Range: [4.71, 6.08]
- n: 5

**ESM**
- Mean: 4.00
- Std Dev: 1.76
- 95% CI: [2.43, 5.57]
- Range: [1.62, 5.66]
- n: 5

**Statistical Analysis**
- Improvement: +28.1%
- t-statistic: 1.894
- p-value: 0.0583
- Cohen's d: 1.198 (large)
- Significant (p<0.05): No

### CPU - Total (%)

**Baseline (epoll)**
- Mean: 9.10
- Std Dev: 0.23
- 95% CI: [8.89, 9.31]
- Range: [8.80, 9.30]
- n: 5

**ESM**
- Mean: 8.76
- Std Dev: 0.37
- 95% CI: [8.43, 9.09]
- Range: [8.30, 9.30]
- n: 5

**Statistical Analysis**
- Improvement: +3.7%
- t-statistic: 1.731
- p-value: 0.0835
- Cohen's d: 1.094 (large)
- Significant (p<0.05): No

### Wakeups per second

**Baseline (epoll)**
- Mean: 57.43
- Std Dev: 14.46
- 95% CI: [44.50, 70.37]
- Range: [44.41, 78.21]
- n: 5

**ESM**
- Mean: 65.98
- Std Dev: 19.11
- 95% CI: [48.89, 83.08]
- Range: [34.62, 80.30]
- n: 5

**Statistical Analysis**
- Improvement: -14.9%
- t-statistic: -0.798
- p-value: 0.4251
- Cohen's d: -0.504 (medium)
- Significant (p<0.05): No

### Power - Idle Battery Drain (%)

**Baseline (epoll)**
- Mean: 2.20
- Std Dev: 1.79
- 95% CI: [0.60, 3.80]
- Range: [0.00, 4.00]
- n: 5

**ESM**
- Mean: 1.20
- Std Dev: 1.64
- 95% CI: [-0.27, 2.67]
- Range: [0.00, 3.00]
- n: 5

**Statistical Analysis**
- Improvement: +45.5%
- t-statistic: 0.921
- p-value: 0.3573
- Cohen's d: 0.582 (medium)
- Significant (p<0.05): No

### Power - Idle Wakeups/sec

**Baseline (epoll)**
- Mean: 6319.64
- Std Dev: 4054.07
- 95% CI: [2693.57, 9945.72]
- Range: [955.42, 9307.54]
- n: 5

**ESM**
- Mean: 470.23
- Std Dev: 372.08
- 95% CI: [137.43, 803.02]
- Range: [193.41, 880.15]
- n: 5

**Statistical Analysis**
- Improvement: +92.6%
- t-statistic: 3.213
- p-value: 0.0013
- Cohen's d: 2.032 (large)
- Significant (p<0.05): Yes

### Power - Active Battery Drain (%)

**Baseline (epoll)**
- Mean: 0.60
- Std Dev: 0.89
- 95% CI: [-0.20, 1.40]
- Range: [0.00, 2.00]
- n: 5

**ESM**
- Mean: 0.20
- Std Dev: 0.45
- 95% CI: [-0.20, 0.60]
- Range: [0.00, 1.00]
- n: 5

**Statistical Analysis**
- Improvement: +66.7%
- t-statistic: 0.894
- p-value: 0.3711
- Cohen's d: 0.566 (medium)
- Significant (p<0.05): No

### Power - Active Wakeups/sec

**Baseline (epoll)**
- Mean: 1042.32
- Std Dev: 110.24
- 95% CI: [943.72, 1140.92]
- Range: [867.92, 1151.72]
- n: 5

**ESM**
- Mean: 210.54
- Std Dev: 15.24
- 95% CI: [196.92, 224.17]
- Range: [194.70, 229.69]
- n: 5

**Statistical Analysis**
- Improvement: +79.8%
- t-statistic: 16.713
- p-value: 0.0000
- Cohen's d: 10.570 (large)
- Significant (p<0.05): Yes

## Conclusions

**Validated claims** (statistically significant improvement):
- Power - Idle Wakeups/sec
- Power - Active Wakeups/sec

**Unvalidated claims** (no significant improvement or regression):
- Latency - Single Tap (ms)
- Latency - Fast Swipe (ms)
- Wakeups per second

