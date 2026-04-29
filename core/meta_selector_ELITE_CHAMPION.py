import os
import pandas as pd
import numpy as np
import plotly.graph_objects as go
from sklearn.tree import DecisionTreeClassifier
from sklearn.preprocessing import StandardScaler
import warnings
warnings.filterwarnings('ignore')

def load_data(folder='backtest_result'):
    files = [f for f in os.listdir(folder) if f.endswith('.csv')]
    all_series = {}
    for f in files:
        try:
            df = pd.read_csv(os.path.join(folder, f), sep=None, engine='python', encoding='utf-16')
            df.columns = [c.replace('<', '').replace('>', '').strip() for c in df.columns]
            df['time'] = pd.to_datetime(df['DATE'])
            df = df.sort_values('time').drop_duplicates('time').set_index('time')
            all_series[f.replace('.csv', '')] = df['EQUITY'].resample('D').ffill()
        except: pass
    return pd.DataFrame(all_series).ffill().dropna()

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)
    data_folder = os.path.join(root_dir, 'backtest_result')
    reports_folder = os.path.join(root_dir, 'reports')
    
    df = load_data(data_folder)
    d_ret = df.pct_change().fillna(0)
    y_class = d_ret.idxmax(axis=1)
    
    all_f = []
    for col in d_ret.columns:
        df_f = pd.DataFrame(index=d_ret.index)
        df_f[f'{col}_l1'] = d_ret[col].shift(1)
        df_f[f'{col}_v10'] = d_ret[col].rolling(10).std().shift(1)
        all_f.append(df_f)
    X = pd.concat(all_f, axis=1).fillna(0)
    
    split = int(len(X) * 0.7)
    X_train_raw = X.iloc[split-90:split]
    y_train = y_class.iloc[split-90:split]
    X_test_raw = X.iloc[split:]
    d_ret_test = d_ret.iloc[split:]
    
    scaler = StandardScaler()
    X_train = scaler.fit_transform(X_train_raw)
    X_test = scaler.transform(X_test_raw)
    
    model = DecisionTreeClassifier(max_depth=5, random_state=42)
    model.fit(X_train, y_train)
    
    probs = model.predict_proba(X_test)
    classes = model.classes_
    
    # ⚡ SELECTIVE SETTINGS FOR 60% WIN RATE
    CONFIDENCE_THRESHOLD = 0.40 # Only trade high probability
    
    ml_ret = pd.Series(0.0, index=d_ret_test.index)
    active_strats = []
    
    for i in range(len(d_ret_test)):
        max_p = np.max(probs[i])
        
        if max_p < CONFIDENCE_THRESHOLD:
            ml_ret.iloc[i] = 0.0
            active_strats.append("CASH")
        else:
            w = np.power(probs[i], 4.0)
            w = w / (np.sum(w) + 1e-9)
            ml_ret.iloc[i] = np.sum([d_ret_test[c].iloc[i] * w[j] for j, c in enumerate(classes)])
            active_strats.append(classes[np.argmax(w)])

    cum_ret = (1 + ml_ret).cumprod() * 100 - 100
    
    # Win Rate calculation only on days we TRADED
    traded_days = ml_ret[ml_ret != 0]
    if len(traded_days) > 0:
        win_rate = (traded_days > 0).mean() * 100
    else:
        win_rate = 0.0
        
    peak = pd.Series(cum_ret).expanding(min_periods=1).max()
    max_dd = (pd.Series(cum_ret) - peak).min()
    
    print(f"\n--- V55 THE SELECTIVE RAINBOW ---")
    print(f"Final Profit (1:1): {cum_ret.iloc[-1]:.2f}%")
    print(f"Max Drawdown: {max_dd:.2f}%")
    print(f"Selective Win Rate: {win_rate:.2f}%")
    print(f"Trading Frequency: {len(traded_days)/len(ml_ret)*100:.2f}% of days")
    
    # RAINBOW HTML GENERATION
    color_palette = ['#EF4444', '#10B981', '#3B82F6', '#F59E0B']
    strat_colors = {col: color_palette[i % len(color_palette)] for i, col in enumerate(df.columns)}
    strat_colors["CASH"] = "#4B5563" # Gray for non-trading days
    
    fig = go.Figure()
    
    # 1. Base Strategies
    for col in df.columns:
        df_strat = df[col].iloc[split:]
        base_curve = (df_strat / df_strat.iloc[0] - 1) * 100
        fig.add_trace(go.Scatter(x=df_strat.index, y=base_curve, 
                                 name=f"Base: {col}", 
                                 line=dict(width=1, dash='dot', color=strat_colors[col]), 
                                 opacity=0.3))

    # 2. Segmented AI Line (Rainbow)
    test_dates = d_ret_test.index
    for i in range(1, len(cum_ret)):
        strat = active_strats[i]
        fig.add_trace(go.Scatter(
            x=[test_dates[i-1], test_dates[i]],
            y=[cum_ret.iloc[i-1], cum_ret.iloc[i]],
            mode='lines',
            line=dict(color=strat_colors[strat], width=4),
            name=f"AI: {strat}",
            showlegend=False,
            hovertemplate=f"Date: %{{x}}<br>Profit: %{{y:.2f}}%<br>Strategy: {strat}<extra></extra>"
        ))

    fig.update_layout(
        title=f"<b>V55 SELECTIVE RAINBOW: Targeted 60% Win Rate</b><br><sup>Profit: {cum_ret.iloc[-1]:.2f}% | DD: {max_dd:.2f}% | Selective Win Rate: {win_rate:.2f}%</sup>",
        template="plotly_dark", paper_bgcolor="#020617", plot_bgcolor="#020617",
        hovermode="x unified", height=850,
        yaxis=dict(title="Profit (%)"),
        xaxis=dict(title="Timeline")
    )
    
    output_html = os.path.join(reports_folder, "final_v55_selective_rainbow.html")
    fig.write_html(output_html)
    print(f"Selective Rainbow Report saved to: {output_html}")
