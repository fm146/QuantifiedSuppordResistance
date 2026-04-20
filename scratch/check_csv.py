import pandas as pd
import os

folder = 'backtest_result'
files = os.listdir(folder)
if files:
    file_path = os.path.join(folder, files[0])
    print(f"Checking file: {file_path}")
    try:
        # Try different encodings
        for enc in ['utf-8', 'utf-16', 'utf-16-le', 'utf-16-be', 'cp1252']:
            try:
                df = pd.read_csv(file_path, sep=None, engine='python', encoding=enc, nrows=5)
                print(f"Success with encoding: {enc}")
                print(df.columns.tolist())
                print(df.head())
                break
            except Exception:
                continue
    except Exception as e:
        print(f"Error: {e}")
else:
    print("No files found in backtest_result")
