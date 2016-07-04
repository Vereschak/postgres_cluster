import psycopg2
import random
from multiprocessing import Process, Value, Queue
import time
import sys
from event_history import *
import select
import signal

class ClientCollection(object):
    def __init__(self, connstrs):
        self._clients = []

        for i, cs in enumerate(connstrs):
            b = BankClient(cs, i)
            self._clients.append(b)

        self._clients[0].initialize()

    @property
    def clients(self):
        return self._clients

    def __getitem__(self, index):
        return self._clients[index]

    def start(self):
        for client in self._clients:
            client.start()

    def stop(self):
        for client in self._clients:
            client.stop()

    def set_acc_to_tx(self, max_acc):
        for client in self._clients:
            client.set_acc_to_tx(max_acc)


class BankClient(object):

    def __init__(self, connstr, node_id, accounts = 10000):
        self.connstr = connstr
        self.node_id = node_id
        self.run = Value('b', True)
        self._history = EventHistory()
        self.accounts = accounts
        self.accounts_to_tx = accounts
        self.show_errors = True

        #x = self
        #def on_sigint(sig, frame):
        #    x.stop()
        #
        #signal.signal(signal.SIGINT, on_sigint)


    def initialize(self):
        conn = psycopg2.connect(self.connstr)
        cur = conn.cursor()
        cur.execute('create extension if not exists multimaster')
        conn.commit()

        cur.execute('create table bank_test(uid int primary key, amount int)')

        cur.execute('''
                insert into bank_test
                select *, 0 from generate_series(0, %s)''',
                (self.accounts,))
        conn.commit()
        cur.close()
        conn.close()

    def aconn(self):
        return psycopg2.connect(self.connstr, async=1)

    @classmethod
    def wait(cls, conn):
        while 1:
            state = conn.poll()
            if state == psycopg2.extensions.POLL_OK:
                break
            elif state == psycopg2.extensions.POLL_WRITE:
                select.select([], [conn.fileno()], [])
            elif state == psycopg2.extensions.POLL_READ:
                select.select([conn.fileno()], [], [])
            else:
                raise psycopg2.OperationalError("poll() returned %s" % state)

    @property
    def history(self):
        return self._history

    def print_error(self, arg, comment=''):
        if self.show_errors:
            print('Node', self.node_id, 'got error', arg, comment)

    def exec_tx(self, name, tx_block):
        conn = psycopg2.connect(self.connstr)
        cur = conn.cursor()

        while self.run.value:
            event_id = self.history.register_start(name)

            if conn.closed:
                self.history.register_finish(event_id, 'ReConnect')
                conn = psycopg2.connect(self.connstr)
                cur = conn.cursor()

            try:
                tx_block(conn, cur)                
                self.history.register_finish(event_id, 'Commit')
            except psycopg2.InterfaceError:
                self.history.register_finish(event_id, 'InterfaceError')
            except psycopg2.Error:
                self.history.register_finish(event_id, 'PsycopgError')

        cur.close()
        conn.close()

    def check_total(self):

        def tx(conn, cur):
            cur.execute('select sum(amount) from bank_test')
            res = cur.fetchone()
            conn.commit()
            if res[0] != 0:
                print("Isolation error, total = %d, node = %d" % (res[0],self.node_id))
                raise BaseException

        self.exec_tx('total', tx)

    def set_acc_to_tx(self, max_acc):
        self.accounts_to_tx = max_acc

    def transfer_money(self):

        def tx(conn, cur):
            amount = 1
            from_uid = random.randrange(1, self.accounts_to_tx - 1)
            to_uid = random.randrange(1, self.accounts_to_tx - 1)

            conn.commit()
            cur.execute('''update bank_test
                set amount = amount - %s
                where uid = %s''',
                (amount, from_uid))
            cur.execute('''update bank_test
                set amount = amount + %s
                where uid = %s''',
                (amount, to_uid))
            conn.commit()

        self.exec_tx('transfer', tx)

    def start(self):
        print('Starting client');
        self.run.value = True

        self.transfer_process = Process(target=self.transfer_money, name="txor", args=())
        self.transfer_process.start()

        self.total_process = Process(target=self.check_total, args=())
        self.total_process.start()

        return

    def stop(self):
        print('Stopping client');
        self.run.value = False
        self.total_process.terminate()
        self.transfer_process.terminate()
        return

    def cleanup(self):
        conn = psycopg2.connect(self.connstr)
        cur = conn.cursor()
        cur.execute('drop table bank_test')
        conn.commit()
        cur.close()
        conn.close()

