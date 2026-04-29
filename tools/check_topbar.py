from lightweight_charts import Chart
import inspect

chart = Chart()
print("Topbar methods:")
if hasattr(chart, 'topbar'):
    for name, obj in inspect.getmembers(chart.topbar):
        if not name.startswith('_'):
            print(f"- {name}: {inspect.signature(obj) if callable(obj) else 'not callable'}")
chart.exit()
