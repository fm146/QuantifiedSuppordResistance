import os
import pandas as pd
from lightweight_charts import Chart

# Premium color palette for distinct lines
COLORS = [
    '#2196F3', # Blue
    '#F44336', # Red
    '#4CAF50', # Green
    '#FF9800', # Orange
    '#9C27B0', # Purple
    '#00BCD4', # Cyan
    '#E91E63', # Pink
    '#FFEB3B', # Yellow
    '#795548', # Brown
    '#607D8B', # Blue Grey
]

def load_backtest_data(file_path):
    """
    Parses MT5 backtest CSV file.
    Handles UTF-16 encoding, cleaning column names, and dropping duplicate timestamps.
    Adds percent return calculation relative to the starting equity.
    """
    try:
        df = pd.read_csv(file_path, sep=None, engine='python', encoding='utf-16')
        
        # Clean column names
        df.columns = [c.replace('<', '').replace('>', '').strip() for c in df.columns]
        
        if 'DATE' in df.columns:
            df['time'] = pd.to_datetime(df['DATE'])
            df = df.sort_values('time')
            # Critical: Drop duplicates as LW Charts doesn't support them
            df = df.drop_duplicates(subset=['time'], keep='last')
            
            # Calculate Percentage Return
            if 'EQUITY' in df.columns:
                initial_equity = df['EQUITY'].iloc[0]
                if initial_equity != 0:
                    # Return % = ((Current / Initial) - 1) * 100
                    df['percent_return'] = ((df['EQUITY'] / initial_equity) - 1) * 100
                else:
                    df['percent_return'] = 0.0
        
        return df
    except Exception as e:
        print(f"Error loading {file_path}: {e}")
        return None

class MultiBacktestViewerV2:
    def __init__(self, folder_path):
        self.folder_path = folder_path
        self.files = [f for f in os.listdir(folder_path) if f.endswith('.csv')]
        
        if not self.files:
            print(f"No CSV files found in {folder_path}")
            return

        # Initialize chart
        self.chart = Chart(toolbox=True, inner_width=1, inner_height=1)
        
        # Premium dark theme
        self.chart.layout(background_color='#0c0d0f', text_color='#d1d4dc', font_size=12)
        self.chart.grid(vert_enabled=True, horz_enabled=True, color='#2b2b43')
        self.chart.legend(visible=True, font_size=11)
        
        # Configure time scale for maximum zooming out
        self.chart.time_scale(min_bar_spacing=0.001)
        
        # Set title
        self.chart.topbar.textbox('title', 'Backtest Performance (%) - Relative to Start')
        
        print(f"Loading {len(self.files)} files and converting to % return...")
        
        for i, filename in enumerate(self.files):
            file_path = os.path.join(folder_path, filename)
            df = load_backtest_data(file_path)
            
            if df is not None and 'percent_return' in df.columns:
                color = COLORS[i % len(COLORS)]
                # Clean up filename for legend
                display_name = filename.replace('.csv', '').replace('supportresistance_', '')
                
                # Create series for this file
                series_name = f"Ret: {display_name} (%)"
                # LW Charts expects 'time' and a value column matching series name
                return_data = df[['time', 'percent_return']].rename(columns={'percent_return': series_name})
                
                line = self.chart.create_line(name=series_name, color=color, width=2)
                line.set(return_data)
                print(f"  - Plotted: {display_name} ({color}) at 0% start")

        self.chart.fit()
        self.chart.show(block=True)

if __name__ == '__main__':
    # Default folder for backtest results
    folder = 'backtest_result'
    if not os.path.exists(folder):
        print(f"Directory {folder} not found.")
    else:
        MultiBacktestViewerV2(folder)
