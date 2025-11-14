#!/usr/bin/env python3

import pandas as pd
import matplotlib.pyplot as plt
import sys
import os

# Read CSV file
csv_file = 'results/results.csv'
if len(sys.argv) > 1:
    csv_file = sys.argv[1]

if not os.path.exists(csv_file):
    print(f"Error: CSV file not found: {csv_file}")
    sys.exit(1)

# Load data
df = pd.read_csv(csv_file)

# Group by scenario and calculate mean QPS
scenario_throughput = df.groupby('scenario')['QPS'].agg(['mean', 'std', 'count']).reset_index()

# Sort by mean throughput for better visualization
scenario_throughput = scenario_throughput.sort_values('mean', ascending=False)

# Create bar chart
fig, ax = plt.subplots(figsize=(12, 6))

# Plot bars with error bars (standard deviation)
bars = ax.bar(scenario_throughput['scenario'], 
              scenario_throughput['mean'],
              yerr=scenario_throughput['std'],
              capsize=5,
              alpha=0.8,
              edgecolor='black',
              linewidth=1.2)

# Add value labels on top of bars
for i, (bar, mean_val, count) in enumerate(zip(bars, scenario_throughput['mean'], scenario_throughput['count'])):
    height = bar.get_height()
    ax.text(bar.get_x() + bar.get_width()/2., height,
            f'{mean_val:,.0f}\n(n={int(count)})',
            ha='center', va='bottom', fontsize=9, fontweight='bold')

# Customize plot
ax.set_xlabel('Scenario', fontsize=12, fontweight='bold')
ax.set_ylabel('Throughput (QPS)', fontsize=12, fontweight='bold')
ax.set_title('Average Throughput by Scenario', fontsize=14, fontweight='bold')
ax.grid(axis='y', alpha=0.3, linestyle='--')

# Rotate x-axis labels for better readability
plt.xticks(rotation=45, ha='right')

# Format y-axis with comma separators
ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda x, p: f'{int(x):,}'))

# Add a subtle background color
ax.set_facecolor('#f9f9f9')

# Tight layout to prevent label cutoff
plt.tight_layout()

# Save figure
output_file = csv_file.replace('.csv', '_throughput.png')
plt.savefig(output_file, dpi=300, bbox_inches='tight')
print(f"Chart saved to: {output_file}")

# Also print statistics
print("\n" + "="*60)
print("Throughput Statistics by Scenario")
print("="*60)
for _, row in scenario_throughput.iterrows():
    print(f"{row['scenario']:20s}: {row['mean']:10,.1f} ± {row['std']:7,.1f} QPS (n={int(row['count'])})")
print("="*60)

# Show plot
plt.show()
