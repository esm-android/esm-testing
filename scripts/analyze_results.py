#!/usr/bin/env python3
"""
analyze_results.py - Statistical analysis of ESM performance test results

Compares baseline (epoll) and ESM test results, calculating:
- Mean, standard deviation, confidence intervals
- Statistical significance (t-test)
- Effect size (Cohen's d)

Generates a comprehensive markdown report.

Usage:
    python3 analyze_results.py
    python3 analyze_results.py --output report.md
"""

import os
import sys
import csv
import argparse
from dataclasses import dataclass
from typing import List, Dict, Optional, Tuple
import math


@dataclass
class Statistics:
    """Statistical summary of a sample."""
    n: int
    mean: float
    std: float
    min_val: float
    max_val: float
    ci_lower: float  # 95% CI lower bound
    ci_upper: float  # 95% CI upper bound


def load_csv(filepath: str) -> List[Dict]:
    """Load CSV file into list of dictionaries."""
    if not os.path.exists(filepath):
        return []

    with open(filepath, 'r') as f:
        reader = csv.DictReader(f)
        return list(reader)


def calculate_stats(values: List[float]) -> Optional[Statistics]:
    """Calculate descriptive statistics for a sample."""
    if not values:
        return None

    n = len(values)
    mean = sum(values) / n

    if n < 2:
        return Statistics(
            n=n, mean=mean, std=0,
            min_val=min(values), max_val=max(values),
            ci_lower=mean, ci_upper=mean
        )

    # Standard deviation
    variance = sum((x - mean) ** 2 for x in values) / (n - 1)
    std = math.sqrt(variance)

    # 95% confidence interval (using t-distribution approximation)
    # For n > 30, z ≈ 1.96
    t_value = 1.96 if n > 30 else 2.0
    margin = t_value * (std / math.sqrt(n))

    return Statistics(
        n=n,
        mean=mean,
        std=std,
        min_val=min(values),
        max_val=max(values),
        ci_lower=mean - margin,
        ci_upper=mean + margin
    )


def welch_t_test(sample1: List[float], sample2: List[float]) -> Tuple[float, float]:
    """
    Perform Welch's t-test for unequal variances.

    Returns (t-statistic, approximate p-value).
    """
    n1, n2 = len(sample1), len(sample2)
    if n1 < 2 or n2 < 2:
        return 0.0, 1.0

    mean1 = sum(sample1) / n1
    mean2 = sum(sample2) / n2

    var1 = sum((x - mean1) ** 2 for x in sample1) / (n1 - 1)
    var2 = sum((x - mean2) ** 2 for x in sample2) / (n2 - 1)

    # Welch's t-statistic
    se = math.sqrt(var1/n1 + var2/n2)
    if se == 0:
        return 0.0, 1.0

    t_stat = (mean1 - mean2) / se

    # Welch-Satterthwaite degrees of freedom
    num = (var1/n1 + var2/n2) ** 2
    denom = (var1/n1)**2/(n1-1) + (var2/n2)**2/(n2-1)
    df = num / denom if denom > 0 else 1

    # Approximate p-value using normal distribution for large df
    # For small df, this underestimates p-value
    z = abs(t_stat)
    p_value = 2 * (1 - normal_cdf(z))

    return t_stat, p_value


def normal_cdf(x: float) -> float:
    """Approximate cumulative distribution function for standard normal."""
    # Using error function approximation
    return 0.5 * (1 + math.erf(x / math.sqrt(2)))


def cohens_d(sample1: List[float], sample2: List[float]) -> float:
    """
    Calculate Cohen's d effect size.

    Interpretation:
    - d < 0.2: negligible
    - 0.2 <= d < 0.5: small
    - 0.5 <= d < 0.8: medium
    - d >= 0.8: large
    """
    n1, n2 = len(sample1), len(sample2)
    if n1 < 2 or n2 < 2:
        return 0.0

    mean1 = sum(sample1) / n1
    mean2 = sum(sample2) / n2

    var1 = sum((x - mean1) ** 2 for x in sample1) / (n1 - 1)
    var2 = sum((x - mean2) ** 2 for x in sample2) / (n2 - 1)

    # Pooled standard deviation
    pooled_std = math.sqrt(((n1-1)*var1 + (n2-1)*var2) / (n1+n2-2))

    if pooled_std == 0:
        return 0.0

    return (mean1 - mean2) / pooled_std


def effect_size_interpretation(d: float) -> str:
    """Interpret Cohen's d value."""
    d = abs(d)
    if d < 0.2:
        return "negligible"
    elif d < 0.5:
        return "small"
    elif d < 0.8:
        return "medium"
    else:
        return "large"


def analyze_metric(
    baseline_values: List[float],
    esm_values: List[float],
    metric_name: str,
    lower_is_better: bool = True
) -> Dict:
    """Analyze a single metric comparing baseline vs ESM."""

    baseline_stats = calculate_stats(baseline_values)
    esm_stats = calculate_stats(esm_values)

    if not baseline_stats or not esm_stats:
        return {'metric': metric_name, 'error': 'Insufficient data'}

    # Calculate improvement
    if lower_is_better:
        improvement = ((baseline_stats.mean - esm_stats.mean) / baseline_stats.mean) * 100
        improved = esm_stats.mean < baseline_stats.mean
    else:
        improvement = ((esm_stats.mean - baseline_stats.mean) / baseline_stats.mean) * 100
        improved = esm_stats.mean > baseline_stats.mean

    # Statistical tests
    t_stat, p_value = welch_t_test(baseline_values, esm_values)
    d = cohens_d(baseline_values, esm_values)

    return {
        'metric': metric_name,
        'baseline': baseline_stats,
        'esm': esm_stats,
        'improvement_pct': improvement,
        'improved': improved,
        't_statistic': t_stat,
        'p_value': p_value,
        'cohens_d': d,
        'effect_size': effect_size_interpretation(d),
        'significant': p_value < 0.05
    }


def generate_report(results: List[Dict], output_path: str) -> None:
    """Generate markdown report from analysis results."""

    with open(output_path, 'w') as f:
        f.write("# ESM Performance Test Results\n\n")
        f.write(f"Generated: {os.popen('date').read().strip()}\n\n")

        f.write("## Summary\n\n")
        f.write("| Metric | Baseline | ESM | Improvement | p-value | Effect Size |\n")
        f.write("|--------|----------|-----|-------------|---------|-------------|\n")

        for r in results:
            if 'error' in r:
                f.write(f"| {r['metric']} | Error: {r['error']} | | | | |\n")
                continue

            baseline = r['baseline']
            esm = r['esm']
            sig = "*" if r['significant'] else ""

            f.write(f"| {r['metric']} | "
                   f"{baseline.mean:.2f} (n={baseline.n}) | "
                   f"{esm.mean:.2f} (n={esm.n}) | "
                   f"{r['improvement_pct']:+.1f}% | "
                   f"{r['p_value']:.4f}{sig} | "
                   f"{r['effect_size']} (d={r['cohens_d']:.2f}) |\n")

        f.write("\n*p < 0.05 (statistically significant)\n\n")

        # Detailed results
        f.write("## Detailed Results\n\n")

        for r in results:
            if 'error' in r:
                continue

            f.write(f"### {r['metric']}\n\n")

            baseline = r['baseline']
            esm = r['esm']

            f.write("**Baseline (epoll)**\n")
            f.write(f"- Mean: {baseline.mean:.2f}\n")
            f.write(f"- Std Dev: {baseline.std:.2f}\n")
            f.write(f"- 95% CI: [{baseline.ci_lower:.2f}, {baseline.ci_upper:.2f}]\n")
            f.write(f"- Range: [{baseline.min_val:.2f}, {baseline.max_val:.2f}]\n")
            f.write(f"- n: {baseline.n}\n\n")

            f.write("**ESM**\n")
            f.write(f"- Mean: {esm.mean:.2f}\n")
            f.write(f"- Std Dev: {esm.std:.2f}\n")
            f.write(f"- 95% CI: [{esm.ci_lower:.2f}, {esm.ci_upper:.2f}]\n")
            f.write(f"- Range: [{esm.min_val:.2f}, {esm.max_val:.2f}]\n")
            f.write(f"- n: {esm.n}\n\n")

            f.write("**Statistical Analysis**\n")
            f.write(f"- Improvement: {r['improvement_pct']:+.1f}%\n")
            f.write(f"- t-statistic: {r['t_statistic']:.3f}\n")
            f.write(f"- p-value: {r['p_value']:.4f}\n")
            f.write(f"- Cohen's d: {r['cohens_d']:.3f} ({r['effect_size']})\n")
            f.write(f"- Significant (p<0.05): {'Yes' if r['significant'] else 'No'}\n\n")

        # Conclusions
        f.write("## Conclusions\n\n")

        validated = []
        refuted = []

        for r in results:
            if 'error' in r:
                continue

            if r['significant'] and r['improved']:
                validated.append(r['metric'])
            elif not r['improved']:
                refuted.append(r['metric'])

        if validated:
            f.write("**Validated claims** (statistically significant improvement):\n")
            for m in validated:
                f.write(f"- {m}\n")
            f.write("\n")

        if refuted:
            f.write("**Unvalidated claims** (no significant improvement or regression):\n")
            for m in refuted:
                f.write(f"- {m}\n")
            f.write("\n")

    print(f"Report generated: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description='Analyze ESM performance test results'
    )
    parser.add_argument('--baseline-dir', default='../results/baseline',
                       help='Directory containing baseline results')
    parser.add_argument('--esm-dir', default='../results/esm',
                       help='Directory containing ESM results')
    parser.add_argument('--output', '-o', default='../report.md',
                       help='Output report path')

    args = parser.parse_args()

    # Resolve paths relative to script location
    script_dir = os.path.dirname(os.path.abspath(__file__))
    baseline_dir = os.path.join(script_dir, args.baseline_dir)
    esm_dir = os.path.join(script_dir, args.esm_dir)
    output_path = os.path.join(script_dir, args.output)

    results = []

    # Analyze latency
    print("Analyzing latency results...")
    baseline_latency = load_csv(os.path.join(baseline_dir, 'latency.csv'))
    esm_latency = load_csv(os.path.join(esm_dir, 'latency.csv'))

    for scenario in ['single_tap', 'scroll', 'fast_swipe']:
        baseline_vals = [float(r['latency_ms']) for r in baseline_latency
                        if r.get('scenario') == scenario and r.get('latency_ms')]
        esm_vals = [float(r['latency_ms']) for r in esm_latency
                   if r.get('scenario') == scenario and r.get('latency_ms')]

        if baseline_vals and esm_vals:
            results.append(analyze_metric(
                baseline_vals, esm_vals,
                f"Latency - {scenario.replace('_', ' ').title()} (ms)",
                lower_is_better=True
            ))

    # Analyze CPU
    print("Analyzing CPU results...")
    baseline_cpu = load_csv(os.path.join(baseline_dir, 'cpu.csv'))
    esm_cpu = load_csv(os.path.join(esm_dir, 'cpu.csv'))

    baseline_ss = [float(r['system_server_cpu']) for r in baseline_cpu
                   if r.get('system_server_cpu')]
    esm_ss = [float(r['system_server_cpu']) for r in esm_cpu
              if r.get('system_server_cpu')]

    if baseline_ss and esm_ss:
        results.append(analyze_metric(
            baseline_ss, esm_ss,
            "CPU - system_server (%)",
            lower_is_better=True
        ))

    baseline_total = [float(r['total_cpu']) for r in baseline_cpu
                      if r.get('total_cpu')]
    esm_total = [float(r['total_cpu']) for r in esm_cpu
                 if r.get('total_cpu')]

    if baseline_total and esm_total:
        results.append(analyze_metric(
            baseline_total, esm_total,
            "CPU - Total (%)",
            lower_is_better=True
        ))

    # Analyze syscalls
    print("Analyzing syscall results...")
    baseline_syscalls = load_csv(os.path.join(baseline_dir, 'syscalls.csv'))
    esm_syscalls = load_csv(os.path.join(esm_dir, 'syscalls.csv'))

    baseline_total_sc = [float(r['total']) for r in baseline_syscalls
                         if r.get('total')]
    esm_total_sc = [float(r['total']) for r in esm_syscalls
                    if r.get('total')]

    if baseline_total_sc and esm_total_sc:
        results.append(analyze_metric(
            baseline_total_sc, esm_total_sc,
            "Syscalls (per 100 events)",
            lower_is_better=True
        ))

    # Analyze wakeups
    print("Analyzing wakeup results...")
    baseline_wakeups = load_csv(os.path.join(baseline_dir, 'wakeups.csv'))
    esm_wakeups = load_csv(os.path.join(esm_dir, 'wakeups.csv'))

    baseline_wps = [float(r['wakeups_per_sec']) for r in baseline_wakeups
                    if r.get('wakeups_per_sec')]
    esm_wps = [float(r['wakeups_per_sec']) for r in esm_wakeups
               if r.get('wakeups_per_sec')]

    if baseline_wps and esm_wps:
        results.append(analyze_metric(
            baseline_wps, esm_wps,
            "Wakeups per second",
            lower_is_better=True
        ))

    # Generate report
    if results:
        generate_report(results, output_path)
    else:
        print("No results to analyze. Run tests first.")


if __name__ == '__main__':
    main()
