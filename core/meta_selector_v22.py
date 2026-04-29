import os
import pandas as pd
import numpy as np
import plotly.graph_objects as go
from sklearn.tree import DecisionTreeClassifier
from sklearn.preprocessing import StandardScaler

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
    # Path handling: Find project root
    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)
    data_folder = os.path.join(root_dir, 'backtest_result')
    reports_folder = os.path.join(root_dir, 'reports')
    
    if not os.path.exists(reports_folder):
        os.makedirs(reports_folder)

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
    
    ml_ret = pd.Series(0.0, index=d_ret_test.index)
    active_strat = []
    for i in range(len(d_ret_test)):
        w = np.power(probs[i], 4.0)
        w = w / (np.sum(w) + 1e-9)
        ml_ret.iloc[i] = np.sum([d_ret_test[c].iloc[i] * w[j] for j, c in enumerate(classes)])
        active_strat.append(classes[np.argmax(w)])

    cum_ret = (1 + ml_ret).cumprod() * 100 - 100
    test_dates = d_ret_test.index
    
    # --- CONSISTENT COLOR MAP ---
    color_palette = ['#EF4444', '#10B981', '#3B82F6', '#F59E0B']
    strat_colors = {col: color_palette[i % len(color_palette)] for i, col in enumerate(df.columns)}
    
    fig = go.Figure()

    for col in df.columns:
        indiv_curve = (1 + d_ret_test[col]).cumprod() * 100 - 100
        fig.add_trace(go.Scatter(
            x=test_dates, y=indiv_curve, 
            name=f"Base: {col}", 
            line=dict(width=1.5, dash='dot', color=strat_colors[col]), 
            opacity=0.4
        ))

    for i in range(1, len(cum_ret)):
        strat = active_strat[i]
        fig.add_trace(go.Scatter(
            x=[test_dates[i-1], test_dates[i]],
            y=[cum_ret.iloc[i-1], cum_ret.iloc[i]],
            mode='lines',
            line=dict(color=strat_colors[strat], width=6),
            name=f"AI Active: {strat}",
            legendgroup=strat,
            showlegend=True if i == active_strat.index(strat) else False,
            hovertemplate=f"Date: %{{x}}<br>Profit: %{{y:.2f}}%<br>Logic: {strat}<extra></extra>"
        ))

    fig.update_layout(
        title="<b>V22 UNIFIED DASHBOARD: Synchronized Strategy Colors</b><br><sup>The thick line color matches the dotted strategy line being followed</sup>",
        template="plotly_dark", paper_bgcolor="#020617", plot_bgcolor="#020617",
        hovermode="closest", height=850,
        legend=dict(orientation="v", yanchor="top", y=1, xanchor="left", x=1.02),
        yaxis=dict(title="Total Profit (%)", gridcolor="#1e293b"),
        xaxis=dict(title="Timeline", gridcolor="#1e293b")
    )
    
    output_html = os.path.join(reports_folder, "final_v22_unified_rainbow.html")
    fig.write_html(output_html)
    print(f"Done! Unified Rainbow Dashboard saved to: {output_html}")


