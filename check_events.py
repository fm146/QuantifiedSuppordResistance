from lightweight_charts import Chart

chart = Chart(toolbox=True)
print("Checking events...")
for name in dir(chart.events):
    if not name.startswith('_'):
        print(f"- {name}")
chart.exit()
