/*
 * Finance: card transactions joined to accounts.
 * Cleans bad dates, null or negative amounts, reversed and duplicate rows. Writes:
 *   monthly_by_segment (month x segment totals), top_merchants (top 10 by spend),
 *   flagged_by_category (transactions above 3x the average of the same account, window function).
 *
 * Input : <input>/finance/<table>.csv   (spark.eval.input,  default hdfs:///evals)
 * Output: <output>/finance/scala/<name>/  CSV with header (spark.eval.output, default hdfs:///evals-out)
 * Run   : spark-shell --master yarn -i finance.scala --conf spark.eval.input=... --conf spark.eval.output=... < /dev/null
 *         (no compile step; spark-shell reads the file and exits. spark-shell runs in client mode only.)
 * Prints: one EVAL_SUMMARY line (same keys in the PySpark and R job), EVAL_HOSTS, EVAL_STATUS.
 */
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.expressions.Window
import org.apache.spark.sql.functions._

val IN  = spark.conf.get("spark.eval.input", "hdfs:///evals")
val OUT = spark.conf.get("spark.eval.output", "hdfs:///evals-out")
spark.conf.set("spark.sql.ansi.enabled", "false") // bad values become null instead of an error

def read(name: String): DataFrame = spark.read.option("header", "true").csv(s"$IN/finance/$name.csv")
def save(df: DataFrame, name: String): Unit =
  df.coalesce(1).write.mode("overwrite").option("header", "true").csv(s"$OUT/finance/scala/$name")
def fmt(d: Double, n: Int): String = String.format(java.util.Locale.ROOT, "%." + n + "f", Double.box(d))
def finish(parts: Int, kv: (String, Any)*): Unit = {
  // Hosts that run a Spark JVM for this application (the driver and the executors).
  val hosts = spark.sparkContext.getExecutorMemoryStatus.keys.map(_.split(":")(0)).toSeq.distinct.sorted.mkString(",")
  val lines = Seq(s"EVAL_SUMMARY domain=finance lang=scala partitions=$parts " + kv.map { case (k, v) => s"$k=$v" }.mkString(" "),
    "EVAL_HOSTS " + hosts, "EVAL_STATUS OK")
  lines.foreach(println)
  import spark.implicits._
  lines.toDF("value").coalesce(1).write.mode("overwrite").text(s"$OUT/finance/scala/summary") // kept for the runner
}

try {
val tx0 = read("transactions")
val raw = tx0.count(); val parts = tx0.rdd.getNumPartitions
val tx = tx0.dropDuplicates("txn_id")
  .withColumn("txn_date", to_date(col("txn_date"), "yyyy-MM-dd"))
  .withColumn("amount", col("amount").cast("double"))
  .withColumn("category", lower(trim(col("category"))))
  .filter(col("txn_date").isNotNull && col("amount") > 0 && col("status") =!= "reversed")
val df = tx.join(read("accounts"), "account_id") // inner join drops orphan accounts

save(df.groupBy(date_format(col("txn_date"), "yyyy-MM").alias("month"), col("segment"))
  .agg(count("*").alias("txns"), round(sum("amount"), 2).alias("total"), round(avg("amount"), 2).alias("avg"))
  .orderBy("month", "segment"), "monthly_by_segment")
save(df.groupBy("merchant").agg(round(sum("amount"), 2).alias("total"), count("*").alias("txns"))
  .orderBy(desc("total"), col("merchant")).limit(10), "top_merchants")
val flag = df.withColumn("flag", (col("amount") > lit(3) * avg("amount").over(Window.partitionBy("account_id"))).cast("int"))
save(flag.groupBy("category").agg(sum("flag").alias("flagged"), count("*").alias("txns"))
  .withColumn("flag_pct", round(lit(100) * col("flagged") / col("txns"), 2)).orderBy("category"), "flagged_by_category")

finish(parts, "raw_rows" -> raw, "clean_rows" -> df.count(), "total_amount" -> fmt(df.agg(sum("amount")).first.getDouble(0), 2),
  "flagged" -> flag.agg(sum("flag")).first.getLong(0))
} catch {
  case e: Throwable => e.printStackTrace(); println("EVAL_STATUS FAIL"); sys.exit(1)
}
sys.exit(0)
