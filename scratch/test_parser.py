import os
import pandas as pd

def test_parsing():
    folder = 'backtest_result'
    files = [f for f in os.listdir(folder) if f.endswith('.csv')]
    for file in files:
        file_path = os.path.join(folder, file)
        print(f"\nProcessing {file}...")
        try:
            df = pd.read_csv(file_path, sep=None, engine='python', encoding='utf-16')
            df.columns = [c.replace('<', '').replace('>', '').strip() for c in df.columns]
            print(f"Columns: {df.columns.tolist()}")
            if 'DATE' in df.columns:
                df['time'] = pd.to_datetime(df['DATE'])
                print(f"Time range: {df['time'].min()} to {df['time'].max()}")
                print(f"Rows: {len(df)}")
            else:
                print("FAILED: DATE column not found")
        except Exception as e:
            print(f"FAILED: {e}")

if __name__ == '__main__':
    test_parsing()
