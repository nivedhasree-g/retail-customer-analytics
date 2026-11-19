#!/usr/bin/env python3
"""
Retail Customer Analytics pipeline
==================================

End-to-end, re-runnable version of the Retail Customer Analysis notebook:

    load -> validate -> clean -> summarise -> RFM score/segment -> charts -> export

Usage
-----
    python src/retail_customer_analysis.py \
        --input data/Retail_Customer_Dataset.xlsx \
        --sheet Raw_Dataset \
        --output-dir outputs

Outputs (written to --output-dir)
---------------------------------
    Retail_Customer_Final_Output_Dataset.xlsx   sheets: Transactions, RFM_Analysis,
                                                Top_100_Customers, High_Value_Customers
    kpi_summary.json                            headline KPIs and cleaning audit trail
    figures/*.png                               the six dashboard charts

The workbook keeps the sheet names and column names the Power BI model expects.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Optional

import matplotlib

matplotlib.use("Agg")  # headless-safe backend; charts are saved, not shown
import matplotlib.pyplot as plt  # noqa: E402
import matplotlib.ticker as mticker  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

LOG = logging.getLogger("retail_analytics")

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
REQUIRED_COLUMNS = [
    "CustomerID",
    "Gender",
    "Age",
    "City",
    "TransactionID",
    "TransactionDate",
    "ProductCategory",
    "Quantity",
    "Price",
    "TotalAmount",
]
TEXT_COLUMNS = ["Gender", "City", "ProductCategory"]
ID_COLUMNS = ["CustomerID", "TransactionID"]

AGE_MIN, AGE_MAX = 18, 90  # ages outside this range are treated as invalid -> imputed
AMOUNT_TOLERANCE = 0.01  # INR; tolerance when comparing TotalAmount to Quantity x Price
HIGH_VALUE_MIN_SCORE = 10  # RFM score 10-12
MEDIUM_VALUE_MIN_SCORE = 7  # RFM score 7-9; 3-6 is Low
SEGMENT_ORDER = ["High Value Customer", "Medium Value Customer", "Low Value Customer"]
SEGMENT_COLOURS = {
    "High Value Customer": "#1b7f5c",
    "Medium Value Customer": "#e0a526",
    "Low Value Customer": "#c0504d",
}
PRIMARY_COLOUR = "#2f5597"
DATE_FORMAT = "%d-%b-%Y"  # e.g. 16-Dec-2024, the format used in the raw file
DEFAULT_SHEET = "Raw_Dataset"
DEFAULT_MAX_VALID_DATE = "2024-12-31"  # end of the observation window; later dates are invalid


# --------------------------------------------------------------------------- #
# Load & validate
# --------------------------------------------------------------------------- #
def load_data(path: Path, sheet: str | int = 0) -> pd.DataFrame:
    """Read the raw dataset from .xlsx/.xls or .csv."""
    if not path.exists():
        raise FileNotFoundError(f"Input file not found: {path}")

    suffix = path.suffix.lower()
    if suffix in {".xlsx", ".xlsm", ".xls"}:
        available = pd.ExcelFile(path).sheet_names
        if sheet not in available and not isinstance(sheet, int):
            if sheet == DEFAULT_SHEET:
                LOG.warning("Sheet '%s' not found; using first sheet '%s'", sheet, available[0])
                sheet = 0
            else:
                raise ValueError(f"Sheet '{sheet}' not found. Available sheets: {available}")
        df = pd.read_excel(path, sheet_name=sheet)
    elif suffix == ".csv":
        df = pd.read_csv(path)
    else:
        raise ValueError(f"Unsupported file type '{suffix}'. Use .xlsx or .csv")

    df.columns = df.columns.astype(str).str.strip()
    LOG.info("Loaded %s rows x %s columns from %s", f"{len(df):,}", df.shape[1], path)
    return df


def validate_schema(df: pd.DataFrame) -> None:
    missing = [c for c in REQUIRED_COLUMNS if c not in df.columns]
    if missing:
        raise ValueError(f"Missing required column(s): {missing}. Found: {list(df.columns)}")


# --------------------------------------------------------------------------- #
# Cleaning
# --------------------------------------------------------------------------- #
def _parse_dates(series: pd.Series) -> pd.Series:
    """Parse dates robustly: native datetimes, the known text format, then day-first fallback."""
    if pd.api.types.is_datetime64_any_dtype(series):
        return series

    parsed = pd.to_datetime(series, format=DATE_FORMAT, errors="coerce")
    retry = parsed.isna() & series.notna()
    if retry.any():
        parsed.loc[retry] = pd.to_datetime(
            series[retry], errors="coerce", dayfirst=True, format="mixed"
        )
    return parsed


def _normalise_text(series: pd.Series) -> pd.Series:
    return (
        series.astype("string")
        .str.strip()
        .str.replace(r"\s+", " ", regex=True)
        .str.title()
        .replace("", pd.NA)  # blank text is treated as missing -> 'Unknown' (same as the SQL view)
    )


def clean_data(raw: pd.DataFrame, max_valid_date: Optional[str] = None) -> tuple[pd.DataFrame, dict]:
    """
    Clean the raw transactions. Returns (clean_df, audit) where audit records how many
    rows were affected by each rule so the run is fully traceable.
    """
    validate_schema(raw)
    df = raw[REQUIRED_COLUMNS].copy()
    audit: dict = {"raw_rows": int(len(df))}

    # 1. Standardise text and identifiers (before de-duplication so near-duplicates match)
    for col in ID_COLUMNS:
        df[col] = df[col].astype("string").str.strip().str.upper()
    for col in TEXT_COLUMNS:
        df[col] = _normalise_text(df[col])
    df["Gender"] = df["Gender"].replace({"M": "Male", "F": "Female"})
    unexpected_gender = sorted(set(df["Gender"].dropna()) - {"Male", "Female"})
    if unexpected_gender:
        LOG.warning("Unexpected Gender values kept as-is: %s", unexpected_gender)
    df[TEXT_COLUMNS] = df[TEXT_COLUMNS].fillna("Unknown")

    # 2. Type coercion (invalid entries become NaN/NaT instead of raising)
    df["TransactionDate"] = _parse_dates(df["TransactionDate"])
    for col in ["Age", "Quantity", "Price", "TotalAmount"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    # 3. Rows we cannot analyse without a key / date
    key_missing = df[ID_COLUMNS + ["TransactionDate"]].isna().any(axis=1)
    audit["dropped_missing_key_or_date"] = int(key_missing.sum())
    df = df.loc[~key_missing]

    # 3b. Dates after the observation window are invalid. Left in, they push the RFM snapshot
    #     date forward and inflate every customer's Recency.
    if max_valid_date:
        after_cutoff = df["TransactionDate"] > pd.Timestamp(max_valid_date)
        audit["dates_after_cutoff_removed"] = int(after_cutoff.sum())
        audit["max_valid_date"] = max_valid_date
        df = df.loc[~after_cutoff]

    # 4. De-duplicate: exact duplicate rows, then repeated TransactionIDs (keep first)
    before = len(df)
    df = df.drop_duplicates()
    audit["exact_duplicates_removed"] = int(before - len(df))
    before = len(df)
    df = df.drop_duplicates(subset="TransactionID", keep="first")
    audit["duplicate_transaction_ids_removed"] = int(before - len(df))

    # 5. Invalid quantity / price (zero, negative or unparseable)
    valid = df["Quantity"].ge(1) & df["Price"].gt(0)
    audit["invalid_quantity_or_price_removed"] = int((~valid).sum())
    df = df.loc[valid].copy()

    if df.empty:
        raise ValueError("No valid rows remain after cleaning; check the input data.")

    # 6. Age: out-of-range -> NaN, then impute with the median of valid ages
    out_of_range = df["Age"].notna() & ~df["Age"].between(AGE_MIN, AGE_MAX)
    df.loc[out_of_range, "Age"] = np.nan
    audit["age_out_of_range_set_null"] = int(out_of_range.sum())
    audit["age_missing_imputed"] = int(df["Age"].isna().sum())
    age_median = df["Age"].median()
    if pd.isna(age_median):
        LOG.warning("No valid ages found; Age left as null")
    else:
        df["Age"] = df["Age"].fillna(age_median)
        audit["age_median_used"] = float(age_median)

    # 7. TotalAmount: fill nulls and repair mismatches against Quantity x Price
    expected = (df["Quantity"] * df["Price"]).round(2)
    null_total = df["TotalAmount"].isna()
    mismatch = ~null_total & ((df["TotalAmount"] - expected).abs().round(2) > AMOUNT_TOLERANCE)
    audit["total_amount_null_recalculated"] = int(null_total.sum())
    audit["total_amount_mismatch_corrected"] = int(mismatch.sum())
    df["TotalAmount"] = np.where(null_total | mismatch, expected, df["TotalAmount"]).round(2)

    # 8. Outlier visibility (flagged, NOT removed: high-ticket Electronics are legitimate)
    q1, q3 = df["TotalAmount"].quantile([0.25, 0.75])
    upper_fence = q3 + 3 * (q3 - q1)
    audit["extreme_high_value_transactions_flagged"] = int((df["TotalAmount"] > upper_fence).sum())

    # 9. Final integrity checks
    df["Quantity"] = df["Quantity"].astype(int)
    df = df.sort_values(["TransactionDate", "TransactionID"]).reset_index(drop=True)
    assert df["TransactionID"].is_unique, "TransactionID must be unique after cleaning"
    assert not df[["CustomerID", "TotalAmount", "TransactionDate"]].isna().any().any()

    audit["clean_rows"] = int(len(df))
    audit["unique_customers"] = int(df["CustomerID"].nunique())
    audit["date_min"] = df["TransactionDate"].min().strftime("%Y-%m-%d")
    audit["date_max"] = df["TransactionDate"].max().strftime("%Y-%m-%d")
    LOG.info("Cleaning audit: %s", json.dumps(audit))
    return df, audit


# --------------------------------------------------------------------------- #
# Exploration summaries
# --------------------------------------------------------------------------- #
def build_summaries(df: pd.DataFrame) -> dict[str, pd.Series]:
    monthly = df.set_index("TransactionDate")["TotalAmount"].resample("MS").sum()
    return {
        "city_revenue": df.groupby("City")["TotalAmount"].sum().sort_values(ascending=False),
        "category_revenue": df.groupby("ProductCategory")["TotalAmount"].sum().sort_values(ascending=False),
        "category_units": df.groupby("ProductCategory")["Quantity"].sum().sort_values(ascending=False),
        "gender_revenue": df.groupby("Gender")["TotalAmount"].sum().sort_values(ascending=False),
        "gender_transactions": df["Gender"].value_counts(),
        "monthly_revenue": monthly,
    }


# --------------------------------------------------------------------------- #
# RFM
# --------------------------------------------------------------------------- #
def build_rfm(df: pd.DataFrame, snapshot_date: Optional[str] = None) -> pd.DataFrame:
    """One row per customer: Recency (days), Frequency (transactions), Monetary (INR)."""
    snapshot = (
        pd.Timestamp(snapshot_date)
        if snapshot_date
        else df["TransactionDate"].max() + pd.Timedelta(days=1)
    )
    rfm = (
        df.groupby("CustomerID")
        .agg(
            last_purchase=("TransactionDate", "max"),
            Frequency=("TransactionID", "nunique"),
            Monetary=("TotalAmount", "sum"),
        )
        .reset_index()
    )
    rfm["Recency"] = (snapshot - rfm["last_purchase"]).dt.days
    rfm["Monetary"] = rfm["Monetary"].round(2)
    rfm = rfm.rename(columns={"CustomerID": "customer_id"})
    return rfm[["customer_id", "Recency", "Frequency", "Monetary"]]


def _quartile_score(values: pd.Series, higher_is_better: bool) -> pd.Series:
    """
    Score 1-4 by quartile. Falls back to rank(method='first') when tied values make the
    quartile edges non-unique (always the case for Frequency), so labels never mismatch.
    """
    labels = [1, 2, 3, 4] if higher_is_better else [4, 3, 2, 1]
    try:
        scores = pd.qcut(values, 4, labels=labels, duplicates="raise")
    except ValueError:
        scores = pd.qcut(values.rank(method="first"), 4, labels=labels)
    return scores.astype(int)


def segment_customer(score: int) -> str:
    if score >= HIGH_VALUE_MIN_SCORE:
        return "High Value Customer"
    if score >= MEDIUM_VALUE_MIN_SCORE:
        return "Medium Value Customer"
    return "Low Value Customer"


def score_rfm(rfm: pd.DataFrame) -> pd.DataFrame:
    if len(rfm) < 4:
        raise ValueError("At least 4 customers are required for quartile scoring.")
    out = rfm.copy()
    out["R_score"] = _quartile_score(out["Recency"], higher_is_better=False)
    out["F_score"] = _quartile_score(out["Frequency"], higher_is_better=True)
    out["M_score"] = _quartile_score(out["Monetary"], higher_is_better=True)
    out["RFM_Score"] = out["R_score"] + out["F_score"] + out["M_score"]
    out["Segment"] = out["RFM_Score"].map(segment_customer)
    return out


# --------------------------------------------------------------------------- #
# Charts
# --------------------------------------------------------------------------- #
def _inr_millions(value: float, _pos=None) -> str:
    return f"{value / 1e6:,.0f}M"


def _finish(fig: plt.Figure, path: Path) -> None:
    fig.tight_layout()
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    LOG.info("Saved %s", path)


def make_charts(rfm: pd.DataFrame, summaries: dict, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    # 1. Revenue by city
    fig, ax = plt.subplots(figsize=(9, 5))
    summaries["city_revenue"].plot(kind="bar", ax=ax, color=PRIMARY_COLOUR)
    ax.set(title="Revenue by City", xlabel="City", ylabel="Total sales (INR millions)")
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(_inr_millions))
    ax.tick_params(axis="x", rotation=45)
    _finish(fig, out_dir / "01_revenue_by_city.png")

    # 2. Revenue share by product category
    fig, ax = plt.subplots(figsize=(7, 7))
    summaries["category_revenue"].plot(kind="pie", ax=ax, autopct="%1.1f%%", startangle=90,
                                       counterclock=False)
    ax.set(title="Revenue Share by Product Category", ylabel="")
    _finish(fig, out_dir / "02_revenue_by_category.png")

    # 3. Monthly revenue trend
    fig, ax = plt.subplots(figsize=(10, 5))
    summaries["monthly_revenue"].plot(kind="line", ax=ax, marker="o", color=PRIMARY_COLOUR)
    ax.set(title="Monthly Revenue Trend", xlabel="Month", ylabel="Total sales (INR millions)")
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(_inr_millions))
    ax.grid(alpha=0.3)
    _finish(fig, out_dir / "03_monthly_revenue_trend.png")

    # 4. Gender-wise spending
    fig, ax = plt.subplots(figsize=(6, 5))
    summaries["gender_revenue"].plot(kind="bar", ax=ax, color=PRIMARY_COLOUR)
    ax.set(title="Gender-wise Total Spending", xlabel="Gender", ylabel="Total amount (INR millions)")
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(_inr_millions))
    ax.tick_params(axis="x", rotation=0)
    _finish(fig, out_dir / "04_gender_spending.png")

    # 5. Customers per RFM segment
    counts = rfm["Segment"].value_counts().reindex(SEGMENT_ORDER).fillna(0).astype(int)
    fig, ax = plt.subplots(figsize=(7, 5))
    ax.bar(counts.index, counts.values, color=[SEGMENT_COLOURS[s] for s in counts.index])
    for i, v in enumerate(counts.values):
        ax.text(i, v, f"{v:,}", ha="center", va="bottom")
    ax.set(title="Customer Count by RFM Segment", xlabel="Customer segment", ylabel="Customers")
    _finish(fig, out_dir / "05_customers_by_segment.png")

    # 6. Recency vs Monetary (customer map)
    fig, ax = plt.subplots(figsize=(8, 5))
    for seg in SEGMENT_ORDER:
        subset = rfm[rfm["Segment"] == seg]
        ax.scatter(subset["Recency"], subset["Monetary"], s=12, alpha=0.6,
                   color=SEGMENT_COLOURS[seg], label=seg)
    ax.set(title="Recency vs Monetary (top-left = ideal customers)",
           xlabel="Recency (days since last purchase)", ylabel="Monetary (INR millions)")
    ax.yaxis.set_major_formatter(mticker.FuncFormatter(lambda v, _p: f"{v / 1e6:,.1f}M"))
    ax.legend()
    _finish(fig, out_dir / "06_recency_vs_monetary.png")


# --------------------------------------------------------------------------- #
# Export
# --------------------------------------------------------------------------- #
def export_results(df: pd.DataFrame, rfm: pd.DataFrame, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "Retail_Customer_Final_Output_Dataset.xlsx"
    top_100 = rfm.sort_values("Monetary", ascending=False).head(100)
    high_value = rfm[rfm["Segment"] == "High Value Customer"]

    with pd.ExcelWriter(path, engine="openpyxl", datetime_format="YYYY-MM-DD") as writer:
        df.to_excel(writer, sheet_name="Transactions", index=False)
        rfm.to_excel(writer, sheet_name="RFM_Analysis", index=False)
        top_100.to_excel(writer, sheet_name="Top_100_Customers", index=False)
        high_value.to_excel(writer, sheet_name="High_Value_Customers", index=False)
    LOG.info("Exported workbook -> %s", path)
    return path


def build_kpis(df: pd.DataFrame, rfm: pd.DataFrame, summaries: dict, audit: dict) -> dict:
    total = float(df["TotalAmount"].sum())
    top3 = summaries["city_revenue"].head(3)
    return {
        "cleaning_audit": audit,
        "total_revenue_inr": round(total, 2),
        "total_revenue_crore": round(total / 1e7, 2),
        "transactions": int(len(df)),
        "unique_customers": int(df["CustomerID"].nunique()),
        "average_customer_age": round(float(df["Age"].mean()), 1),
        "top_3_cities": top3.index.tolist(),
        "top_3_city_revenue_share_pct": round(float(top3.sum() / total * 100), 1),
        "top_category_by_revenue": summaries["category_revenue"].index[0],
        "top_category_by_units": summaries["category_units"].index[0],
        "segment_counts": rfm["Segment"].value_counts().reindex(SEGMENT_ORDER).fillna(0).astype(int).to_dict(),
    }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Retail customer analytics & RFM segmentation pipeline")
    p.add_argument("--input", type=Path, default=Path("data/Retail_Customer_Dataset.xlsx"))
    p.add_argument("--sheet", default=DEFAULT_SHEET,
                   help=f"Excel sheet name or index (default: {DEFAULT_SHEET}, else first sheet)")
    p.add_argument("--output-dir", type=Path, default=Path("outputs"))
    p.add_argument("--max-valid-date", default=DEFAULT_MAX_VALID_DATE,
                   help="Latest valid transaction date YYYY-MM-DD; later rows are removed "
                        f"(default: {DEFAULT_MAX_VALID_DATE}; use 'none' to disable)")
    p.add_argument("--snapshot-date", default=None,
                   help="RFM reference date YYYY-MM-DD (default: last transaction date + 1 day)")
    p.add_argument("--no-charts", action="store_true", help="Skip chart generation")
    p.add_argument("-v", "--verbose", action="store_true")
    return p.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s | %(levelname)-7s | %(message)s")
    sheet: str | int = int(args.sheet) if str(args.sheet).isdigit() else args.sheet

    try:
        raw = load_data(args.input, sheet)
        max_date = None if str(args.max_valid_date).lower() == "none" else args.max_valid_date
        clean, audit = clean_data(raw, max_date)
        summaries = build_summaries(clean)
        rfm = score_rfm(build_rfm(clean, args.snapshot_date))
        export_results(clean, rfm, args.output_dir)
        if not args.no_charts:
            make_charts(rfm, summaries, args.output_dir / "figures")
        kpis = build_kpis(clean, rfm, summaries, audit)
        (args.output_dir / "kpi_summary.json").write_text(json.dumps(kpis, indent=2))
        LOG.info("KPIs: %s", json.dumps({k: v for k, v in kpis.items() if k != "cleaning_audit"}))
    except (FileNotFoundError, ValueError) as exc:
        LOG.error("%s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
