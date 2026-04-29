from lightweight_charts import Chart
import inspect

chart = Chart()
print("Attributes of Chart object:")
for name, obj in inspect.getmembers(chart):
    if not name.startswith('_'):
        print(f"- {name}")
chart.exit()
