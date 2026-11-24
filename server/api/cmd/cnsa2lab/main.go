// cnsa2lab makes a test account in a scratch database, for exercising CNSA 2.0
// enrollment against a locally run API. Lab only: it needs the database file
// and the account-number secret, so it can do nothing a person with those
// could not already do. Never point it at the production database.
//
//	cnsa2lab -db /tmp/lab.db -secret <ACCOUNT_NUMBER_SECRET> [-limit 3] [-days 30]
package main

import (
	"flag"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/cloakvpn/api/internal/account"
	"github.com/cloakvpn/api/internal/store"
)

func main() {
	dbPath := flag.String("db", "", "scratch database path")
	secret := flag.String("secret", "", "account number secret the local API runs with")
	limit := flag.Int("limit", 3, "device limit")
	days := flag.Int("days", 30, "days of subscription (negative for a lapsed account)")
	flag.Parse()
	if *dbPath == "" || *secret == "" {
		log.Fatal("-db and -secret are required")
	}
	if strings.HasPrefix(*dbPath, "/var/lib/cloakvpn") {
		log.Fatal("refusing to touch the production database path")
	}
	db, err := store.Open(*dbPath)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	num, err := account.Generate()
	if err != nil {
		log.Fatal(err)
	}
	txn := fmt.Sprintf("cnsa2lab-%d", time.Now().UnixNano())
	if _, err := db.CreateAccountApple(account.Hash(num, *secret), txn, store.TierBasic, *limit,
		time.Now().Add(time.Duration(*days)*24*time.Hour)); err != nil {
		log.Fatal(err)
	}
	fmt.Println(num)
}
