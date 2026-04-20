from lightweight_charts import Chart
import inspect

chart = Chart(toolbox=True)
print("Checking toolbox and line detection...")
print(f"Chart has 'lines' attr: {hasattr(chart, 'lines')}")
if hasattr(chart, 'lines'):
    print(f"Chart 'lines' type: {type(chart.lines)}")

# Check toolbox events
if hasattr(chart, 'toolbox'):
    print("Toolbox attributes:")
    for name in dir(chart.toolbox):
        if not name.startswith('_'):
            print(f"- {name}")

chart.exit()
