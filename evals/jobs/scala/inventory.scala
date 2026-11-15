/*
 * Inventory: stock movements joined to products.
 * Cleans bad dates, null quantities, unknown SKUs, duplicates. Writes:
 *   warehouse_category (net units and stock value), top_outbound (top 10 SKUs by units out),
 *   stockouts (moves that took running stock below 0, per warehouse, window running sum).
 *
 * Input : <input>/inventory/<table>.csv   (spark.eval.input,  default hdfs:///evals)
 * Output: <output>/inventory/scala/<name>/  CSV with header (spark.eval.output, default hdfs:///evals-out)
 * Run   : spark-shell --master yarn -i inventory.scala --conf spark.eval.input=... --conf spark.eval.output=... < /dev/null
 *         (no compile step; spark-shell reads the file and exits. spark-shell runs in client mode only.)
 * Prints: one EVAL_SUMMARY line (same keys in the PySpark and R job), EVAL_HOSTS, EVAL_STATUS.
 */
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.expressions.Window
import org.apache.spark.sql.functions._

val IN  = spark.conf.get("spark.eval.input", "hdfs:///evals")
val OUT = spark.conf.get("spark.eval.output", "hdfs:///evals-out")
spark.conf.set("spark.sql.ansi.enabled", "false") // bad values become null instead of an error

def read(name: String): DataFrame = spark.read.option("header", "true").csv(s"$IN/inventory/$name.csv")
def save(df: DataFrame, name: String): Unit =
  df.coalesce(1).write.mode("overwrite").option("header", "true").csv(s"$OUT/inventory/scala/$name")
def fmt(d: Double, n: Int): String = String.format(java.util.Locale.ROOT, "%." + n + "f", Double.box(d))
def finish(parts: Int, kv: (String, Any)*): Unit = {
  // Hosts that run a Spark JVM for this application (the driver and the executors).
  val hosts = spark.sparkContext.getExecutorMemoryStatus.keys.map(_.split(":")(0)).toSeq.distinct.sorted.mkString(",")
  val lines = Seq(s"EVAL_SUMMARY domain=inventory lang=scala partitions=$parts " + kv.map { case (k, v) => s"$k=$v" }.mkString(" "),
    "EVAL_HOSTS " + hosts, "EVAL_STATUS OK")
  lines.foreach(println)
  import spark.implicits._
  lines.toDF("value").coalesce(1).write.mode("overwrite").text(s"$OUT/inventory/scala/summary") // kept for the runner
}

try {
val mv0 = read("stock_moves")
val raw = mv0.count(); val parts = mv0.rdd.getNumPartitions
val mv = mv0.dropDuplicates("move_id")
  .withColumn("move_date", to_date(col("move_date"), "yyyy-MM-dd"))
  .withColumn("qty_change", col("qty_change").cast("int"))
  .filter(col("move_date").isNotNull && col("qty_change").isNotNull)
val prod = read("products").withColumn("unit_cost", col("unit_cost").cast("double")).withColumn("reorder_level", col("reorder_level").cast("int"))
val df = mv.join(prod, "sku") // inner join drops unknown SKUs

save(df.groupBy("warehouse", "category")
  .agg(sum("qty_change").alias("net_units"), round(sum(col("qty_change") * col("unit_cost")), 2).alias("stock_value"))
  .orderBy("warehouse", "category"), "warehouse_category")
save(df.filter(col("qty_change") < 0).groupBy("sku").agg(sum(-col("qty_change")).alias("units_out"))
  .orderBy(desc("units_out"), col("sku")).limit(10), "top_outbound")
val w = Window.partitionBy("sku", "warehouse").orderBy("move_date", "move_id").rowsBetween(Window.unboundedPreceding, Window.currentRow)
val stock = df.withColumn("running", sum("qty_change").over(w)).filter(col("running") < 0)
  .groupBy("warehouse").agg(count("*").alias("stockout_moves")).orderBy("warehouse")
save(stock, "stockouts")

val below = df.groupBy("sku", "reorder_level").agg(sum("qty_change").alias("stock")).filter(col("stock") < col("reorder_level")).count()
finish(parts, "raw_rows" -> raw, "clean_rows" -> df.count(), "net_units" -> df.agg(sum("qty_change")).first.getLong(0),
  "stockout_moves" -> stock.agg(sum("stockout_moves")).first.getLong(0), "skus_below_reorder" -> below)
} catch {
  case e: Throwable => e.printStackTrace(); println("EVAL_STATUS FAIL"); sys.exit(1)
}
sys.exit(0)
