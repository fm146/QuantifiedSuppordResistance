from lightweight_charts import Chart
import time

def test():
    chart = Chart(toolbox=True)
    # Give user a few seconds to draw something? No, this is non-interactive.
    # I'll just check if the method exists and what it returns for empty.
    if hasattr(chart, 'toolbox'):
        print(f"Export drawings result (empty): {chart.toolbox.export_drawings()}")
    chart.exit()

if __name__ == "__main__":
    test()
